# palimpsest-system — NOTES

Written for the person carrying this to the laptop. It assumes you know Linux
well and Nix barely at all, which is the stated situation.

**Read §1 and §2 before you install anything.** The rest can wait until
something misbehaves.

---

## 1. What I actually verified, and how

I had a working `nix` on the authoring workstation and network access to
nixpkgs, so most of this config is not "believed correct" — it was checked
against the real module source at the pinned commit, and the whole system was
built end to end.

Pinned commit: `nixos-26.05` at `531670d871c0e29724a02f3cbcac170adc65b58c`
(2026-08-03), recorded in `flake.lock`.

**The config was also booted.** I built the test VM, added a temporary oneshot
service that runs `scripts/verify-contract` at boot, and ran it under KVM. Result
against **contract v3**: **42 passed, 0 failed, 7 informational** (the
informational ones are the GPU checks, which no VM can pass, plus the §5.2
reminder). So the following are observed behaviour on a running system, not
predictions:

- `media` 1500/1500, `frank` 1000, `render` 303, `media` shell = `nologin`
- `/data`, `/opt/palimpsest-stack` and the whole media tree created by
  systemd-tmpfiles at `1500 1500 775`
- `/data/transcode` mounted as tmpfs with the right ownership
- all five sleep targets **masked**; `HandleLidSwitch=ignore` present in the
  generated `logind.conf`
- docker running; `palimpsest-stack.service` present and **not** started at boot
- the stack unit carries `After=docker.service tailscaled.service`, all three
  `RequiresMountsFor` paths including `/data/transcode`, and an `ExecStartPre`
- the firewall's LAN rule covers tcp/22, tcp/8096 and udp/1900+7359, names no
  Docker-published port, and the tailscale0 interface rule is present
- **the hardlink test passes** — `/data/torrents` → `/data/media`, same inode

The `ExecStartPre` tailscale0 wait was tested separately, since the stack unit
does not start in the VM: **6 ms exit 0** against an interface that has an IPv4
address, and a clean **60 s exit 1** with the intended journal line against one
that does not.

That VM run also caught three real bugs before you ever touched the laptop; they
are described in §3.5.

Verified by building, not by reading:

- The complete system closure builds: `nixos-system-palimpsest-26.05...`, kernel
  **6.18.41** (comfortably new enough for Alder Lake `i915`).
- The **nftables ruleset is syntactically valid**. NixOS runs `nft --check` on
  it at build time (`networking.nftables.checkRuleset` defaults true), so a
  successful build is real evidence the firewall will load. This matters: a
  broken ruleset on a headless box means no SSH.
- The generated `palimpsest-stack.service` unit text matches contract §3
  line for line, including no `[Install]` section — i.e. it genuinely ships
  disabled.
- Contract §1 identity, read back out of the evaluated config:
  `frank` uid 1000, `media` uid 1500, `media` gid 1500, `render` gid 303,
  `media` shell resolves to `${shadow}/bin/nologin`.

Package/option names resolved against the pinned tree rather than from memory:

| Thing | Result |
|---|---|
| `hardware.opengl.*` | **Gone entirely** in 26.05 — not even a deprecation alias. Used `hardware.graphics.*`. |
| `vaapiIntel` | **Does not exist.** (Legacy driver survives as `intel-vaapi-driver`; contract §4 forbids it anyway.) |
| `onevpl-intel-gpu` | **Does not exist.** |
| `intel-media-sdk` | Exists but is the legacy MSDK, stuck at 23.2.2. Wrong for Alder Lake. |
| `vpl-gpu-rt` | **Exists, 26.1.6 — this is the right one.** Same version as `intel-media-driver` 26.1.6; they are two halves of one Intel release. |
| `services.logind.lidSwitch` | Now only a *renamed alias* (deprecation warning). `services.logind.extraConfig` is **removed** and fails to evaluate. Used `services.logind.settings.Login.*`. |
| `claude-code` | Exists, **2.1.187**, and is **unfree**. |
| `docker` | 29.6.2, and `pkgs.docker` bundles the compose plugin by default, so `docker compose` works with no extra package. |

### The Claude Code question, answered

Prompt 1 asked three things. Answers: (a) `claude-code` exists at the top level
of the pinned release, so the attribute path is just `pkgs.claude-code`;
(b) it **is unfree**, so it needs an allowlist entry, which is in
`modules/base.nix` as an `allowUnfreePredicate` naming only that one package
rather than a blanket `allowUnfree = true`; (c) at 2.1.187 the stable version is
**not** too old, so **no second unstable flake input was added**. The system
stays on one pinned nixpkgs.

---

## 2. Two things you must know before installing

### 2.1 Merging the generated hardware config — THE MOST LIKELY INSTALL FAILURE

`hosts/palimpsest/hardware-configuration.nix` in this repo is a **placeholder
with invented UUIDs**. It exists only so the config can be evaluated off-target.
It will not boot the laptop.

You will replace it with the output of `nixos-generate-config`.

**`INSTALL.md` avoids this problem entirely by not mounting `/data` during the
install** — `nixos-generate-config` only emits entries for filesystems mounted
at the time it runs, so if `/data` is not mounted, nothing collides and there is
nothing to clean up. `/data` mounts normally on the first real boot; it does not
need to exist during installation. Follow INSTALL.md §4 and you can skip the
rest of this section.

If you *did* mount `/data` before generating, **the generated file will contain
entries that collide with `modules/storage.nix`** and Nix will refuse to build
with `The option 'fileSystems."/data"' has conflicting definitions`. The fix is
to open the generated file and **delete**:

- the whole `fileSystems."/data" = { ... };` block
- the whole `fileSystems."/data/transcode" = { ... };` block, if present
- any `swapDevices` entry, if you did not create swap (we use zram instead)

Keep everything else, especially `fileSystems."/"`, `fileSystems."/boot"`, and
the `boot.initrd.availableKernelModules` list.

Why `/data` lives in `modules/storage.nix` and not in the hardware file: prompt
1 asked that moving `/data` to a real disk later be a one-line change. If it
lived in the hardware config it would be rewritten every time you regenerate.

**Other things in the generated file that could conflict with mine**, none of
which have bitten in testing but all of which are worth a glance:

- `networking.useDHCP = lib.mkDefault true` — fine, `mkDefault` yields to
  anything I set. I set nothing, so DHCP is on. Intended.
- `nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux"` — fine.
- `hardware.cpu.intel.updateMicrocode = lib.mkDefault true` — fine, and wanted.
- `boot.kernelModules = [ "kvm-intel" ]` — fine.
- If it emits anything under `hardware.graphics` or `services.xserver`, delete
  it; `modules/graphics.nix` owns that.

### 2.2 The disk label is not optional

`modules/storage.nix` mounts `/data` from `/dev/disk/by-label/palimpsest-data`.
If you format that partition without `-L palimpsest-data`, `/data` will not
mount. Because I set `nofail` (deliberately — see below), **the machine will
boot anyway** and you will get a working SSH session with a silently empty
`/data`. `scripts/verify-contract` catches this explicitly; it is the
`"/data is NOT mounted"` check.

The `nofail` choice: without it, a missing `/data` drops the boot to an initrd
emergency shell, which on a headless laptop on a shelf means carrying a monitor
to it. With it, the box boots, SSH works, you debug remotely — and the container
stack still cannot start, because its unit carries
`RequiresMountsFor=/data`. Boot succeeds, stack stays down, nothing writes media
to the wrong filesystem. That is the correct failure mode here.

---

## 3. What I am least confident about

Ranked by how likely it is to actually bite you.

### 3.1 The dGPU reaching D3cold — SOLVED, and the fix was not the obvious one

Resolved on the real machine on 2026-08-04. Recorded because the diagnosis is
the useful part.

Blacklisting `nouveau` was necessary but **not sufficient**, exactly as feared.
First measurement after install:

```
/sys/bus/pci/devices/0000:01:00.0/power/control  ->  on
/sys/bus/pci/devices/0000:01:00.0/power_state    ->  D0
```

No driver was bound — the blacklist worked — but the card sat in D0 anyway.
**An unbound PCI device does not runtime-suspend by itself.** Runtime PM is
normally enabled by the driver, so with no driver there is nothing to enable it,
`power/control` stays at `on`, and the card idles at full power indefinitely.

It was not the firmware, and it was not the audio function. `d3cold_allowed` was
already `1`, and `01:00.1` was already `auto` (snd_hda_intel enables runtime PM
itself). One attribute on the VGA function was the whole problem:

```bash
echo auto > /sys/bus/pci/devices/0000:01:00.0/power/control
```

Both functions dropped to `D3cold` within seconds. That is 10-15 W recovered.

Now permanent as a udev rule in `modules/power.nix` matching vendor `0x10de`,
which covers both functions. `scripts/verify-contract` treats a non-D3cold
reading as a FAIL rather than an informational line, since it is now a
regression rather than an open question.

**The generalisable bit:** "no driver is bound" and "the device is powered down"
are different claims. The first does not imply the second, and on a laptop the
gap between them is 10-15 W.

**And a second lesson, from the check itself.** After the udev rule landed, a
manual read showed `D3cold` but `scripts/verify-contract` reported `D0` seconds
later. The rule was fine; the *check* was wrong. It located the card with
`lspci`, which reads PCI **config space** — and the kernel must runtime-resume a
D3cold device to service that read. The check powered the GPU on and then
faithfully reported that the GPU was on.

The script now finds the device by reading `vendor` and `class` from sysfs,
which are cached from enumeration and touch no hardware. If you ever need to
observe a suspended device's state, **do not use `lspci`** — it is not a passive
observer. `cat /sys/bus/pci/devices/<addr>/power_state` is.

### 3.2 GuC/HuC firmware for low-power encode — probably fine, unconfirmed

Jellyfin's "Intel Low-Power H.264/HEVC encoder" needs HuC authenticated. Recent
kernels default to loading GuC+HuC on Gen12+ (Alder Lake qualifies), so this
most likely needs nothing — but I did not confirm the default for the exact
kernel this release ships (6.18.41).

```bash
sudo dmesg | grep -iE 'i915.*(guc|huc)'
```

If HuC is not authenticated, the one-line fix is commented in
`modules/graphics.nix`: `boot.kernelParams = [ "i915.enable_guc=3" ];`. Do not
add it pre-emptively.

### 3.3 Tailscale and the nftables backend

Tailscale installs its own nftables rules alongside the NixOS firewall. This is
a supported combination and is what most NixOS+Tailscale users run, but I could
not exercise it without joining a real tailnet.

I set `checkReversePath = "loose"` in `modules/networking.nix` because strict
reverse-path filtering is the classic cause of "tailnet pings but TCP hangs".
The NixOS tailscale module only relaxes it automatically when
`useRoutingFeatures` is `client`/`both`, and this node is neither a subnet
router nor an exit node, so it would otherwise have been left strict.

If the tailnet misbehaves, check `nft list ruleset` for tailscale's own tables
before touching mine.

### 3.4 The VM does not test everything

See §6.

### 3.5 Three bugs the VM run caught

Recording these because each was silent — none produced an error, a warning, or
a failed build. They are all fixed; this is about what to distrust next time.

1. **`services.openssh.openFirewall` defaults to `true`.** It appends port 22 to
   `networking.firewall.allowedTCPPorts`, and because that is a separate option
   definition it *merges past* the `allowedTCPPorts = [ ]` in
   `modules/networking.nix` rather than being overridden by it. The generated
   ruleset had a bare `tcp dport { 22 } accept` at the top of the input chain —
   SSH open on every interface from any source, contrary to contract §5. Found
   by reading the generated nftables ruleset, not the config. Fixed in
   `modules/base.nix`; the comment there explains why the line must stay.

2. **`mkVMOverride` (priority 10) outranks `mkForce` (priority 50).**
   `modules/vm.nix` originally overrode the VM's `/data` with
   `fileSystems."/data" = lib.mkForce {...}`. qemu-vm.nix replaces the entire
   `fileSystems` attrset with `virtualisation.fileSystems` at a stronger
   priority, so the override was silently dropped — no error, no mount, and
   `/data` quietly became an ordinary directory on the VM's root disk. Found
   only by booting and looking. Now uses `virtualisation.fileSystems`.

3. **`systemctl is-enabled` returns `linked`, not `disabled`,** for a NixOS unit
   with no `[Install]` section — which is exactly what `wantedBy = [ ]`
   produces. `scripts/verify-contract` was calling the correct state a failure.
   Both `linked` and `disabled` are now accepted.

The general lesson, which applies to the two items above that remain unverified:
**evaluating a Nix config proves the option names exist; it does not prove the
resulting system behaves.** For anything security- or boot-critical, read the
generated artifact (`nft list ruleset`, the unit text) or boot it.

---

## 4. Contract observations

This config is built against **contract v3 (2026-08-04)**. Everything this layer
flagged against v1 was amended in v2 rather than worked around, which is the
outcome the flagging was for. Kept here as a record of why the rules look the
way they do.

### 4.1 RESOLVED in v2 — DLNA discovery ports

**Was:** contract v1 justified Jellyfin's host networking by citing DLNA and
client auto-discovery, then opened only TCP 8096 — so discovery could not
actually work. Host networking let Jellyfin *send* discovery traffic, but
inbound probes from LAN clients were dropped.

**Now:** v2 §5.1 adds **UDP 1900** (SSDP) and **UDP 7359** (Jellyfin's own
broadcast), LAN-only. Implemented in `modules/networking.nix` as a second
`extraInputRules` line. They are deliberately *not* on the tailscale0 port list:
broadcast discovery does not work across a tailnet, so opening them there would
be surface without function.

### 4.2 RESOLVED in v2 — UDP 41641 is now disclosed

**Was:** `services.tailscale.openFirewall = true` opened UDP 41641 on all
interfaces, and contract v1's table did not mention it — an undocumented open
port on a default-deny box.

**Now:** v2 §5.1 lists it explicitly as Tailscale transport rather than an
application port. Behaviour is unchanged; the disclosure is the fix. Without it
peer traffic relays through DERP, which is slow for video. Nothing is forwarded
at the router, so in practice it is LAN-reachable only. Set
`openFirewall = false` if you would rather have the relay.

### 4.3 Still deliberate: `After=`, not `Requires=`

Contract v2 §3 specifies `After=docker.service tailscaled.service`, and that is
what is implemented. A stricter `Requires=` would be defensible — as written, if
docker is not running the unit starts and fails rather than pulling docker in —
but the contract says ordering, and quietly upgrading it is not mine to do.
Failing loudly is the wanted behaviour, and this was confirmed as correct on
review.

Note the *precondition* is a different mechanism from the *ordering*: ordering
after `tailscaled.service` only means the daemon started, so v2 §3 also requires
the bounded `ExecStartPre` poll for an actual IPv4 address on `tailscale0`. See
§4.5.

### 4.4 DONE — the stale build doc has been deleted

`x17r2-jellyfin-build.md` contradicted the contract (UID 1000, `/opt/stack`,
tmpfs owned 1000:1000) and both sessions correctly ignored it. Contract v2 §0
now forbids committing pre-contract design docs, and the file has been removed
so it cannot mislead a later session. The parts still worth having are folded
into §8 below.

### 4.5 New in v2: the stack unit waits for a tailnet address

The stack binds its admin UIs to this machine's tailnet address (v2 §5.2,
`BIND_ADDR_TAILNET`), and Docker cannot bind an address that does not exist yet.

`modules/containers.nix` now carries a bounded `ExecStartPre` that polls for an
IPv4 address on `tailscale0` for 60 seconds and **exits non-zero** on timeout.
Both paths were tested directly: 6 ms exit 0 against an interface that has an
address, and a clean 60 s exit 1 with the intended journal line against one that
does not.

Consequence worth knowing: on a node where `tailscale up` has never been run,
starting the stack fails after 60 seconds *by design*. INSTALL.md authenticates
Tailscale (§10) before ever starting the stack (§14).

### 4.6 Read v2 §5.2 before debugging an unreachable admin UI

v2 added a contract-level rule about Docker's firewall bypass. Nothing in this
repo implements it — exposure for published ports is controlled by the stack's
bind address — but it changes how you *debug* this layer, so it is summarised in
CLAUDE.md and at the top of `modules/networking.nix`.

The short version: Docker publishes via DNAT in `PREROUTING`, which never
traverses the `INPUT` chain this firewall lives in. For anything Docker
publishes, these rules are the second layer. Opening a port here will not fix an
unreachable admin UI and will only widen the firewall. Jellyfin is the exception
— host-networked, not published by Docker, so 8096/1900/7359 are protected by
this layer and nothing else.

---

### 4.7 v3 corrected a defect in v2 that this layer had implemented faithfully

Worth recording as its own lesson, because nothing in this repo was wrong by its
own lights.

v2 §5.2 stated that LAN-published services were bounded by host-firewall source
rules. That could not be true, and v2's own opening paragraph said why: Docker
DNATs published ports in `PREROUTING`, so they never reach `INPUT`. This layer
implemented the table as written — 5055 went into the RFC1918 rule, and the six
admin-UI ports sat on the `tailscale0` list — and the verifier asserted them and
passed. A wrong contract propagates *because* both halves trust it.

**What changed in v3:** no `INPUT` rule may name a Docker-published port. 5055
came out of the RFC1918 rule; 5055 and 6767/7878/8080/8081/8989/9696 came out of
the `tailscale0` list. The firewall now contains only host-bound services — 22,
8096, and udp 1900/7359. The verifier's tcp/5055 assertion was deleted and
replaced with the inverse: a check that **no** Docker-published port appears.

**Real exposure did not change by one packet.** Those rules were never
consulted. What was removed was a false belief — which over a five-year life is
the more dangerous of the two.

**How to catch this class of thing:** ask whether traffic to a port actually
reaches `INPUT` before writing a rule for it. Confirmed while implementing v3:
`networking.firewall.filterForward` defaults to `false`, so this config does not
filter forwarding either — there is genuinely no host-firewall involvement in
Docker-published traffic in either direction.

Docker-published exposure cannot be verified by this layer at all. The check
with teeth is contract §7.2's `ss -ltnp` listener scan, run after bring-up.

### 4.8 New in v3: restart policy, but only when enabled at boot

`Restart=on-failure`, `RestartSec=30`, `StartLimitIntervalSec=600`,
`StartLimitBurst=5` — applied only when `enableAtBoot` is `true`. While the unit
ships disabled it has no restart policy at all, so a hand-started unit fails in
front of you instead of retrying while you read the journal.

This does not contradict "no restart policy; per-container `restart:
unless-stopped` handles recovery". That rule prevents systemd and Docker
fighting over *running* containers. This covers a unit that **never started** —
if the tailscale0 poll times out at boot, no container was ever created, so
Docker has nothing to recover and the stack would otherwise stay down until a
human noticed.

Both branches were verified by generating the unit each way. Note
`StartLimitIntervalSec`/`StartLimitBurst` are emitted into **`[Unit]`**, not
`[Service]` — systemd moved them in v229 and ignores them in `[Service]`, which
would have produced an unbounded restart loop instead of a bounded one.

## 5. What you must do by hand

No secrets are in this repo (contract §6). These are the steps that need a
human.

1. **BIOS first**, per INSTALL.md §1. Especially: graphics mode
   **Hybrid/Optimus** (discrete-only kills QuickSync), AC power recovery **on**,
   Secure Boot **off**.
2. **Root password** — `nixos-install` prompts for one at the end. That is the
   only credential created during install.
3. **First console login.** SSH has `PasswordAuthentication = false` and `frank`
   has **no password and no key** — deliberately, so nothing credential-shaped
   lives in git. On first boot, log in as `root` at the laptop's own keyboard:
   ```bash
   passwd frank
   ```
   This password is for the **console and sudo only**. It does not work over
   SSH — see the next item.
4. **Tailscale, BEFORE the SSH key.** This ordering is not optional and the
   obvious order does not work.
   ```bash
   sudo tailscale up --ssh
   ```
   `--ssh` makes tailscaled terminate SSH itself on the tailnet address, never
   consulting OpenSSH, so it is the only way in that needs no pre-existing
   credential. The node key persists in `/var/lib/tailscale` across reboots and
   rebuilds.
5. **Install your SSH key** — for LAN reachability; Tailscale already works.
   **`ssh-copy-id` CANNOT be used here.** It authenticates over SSH to append
   the key, but sshd offers `publickey` only (`PasswordAuthentication` and
   `KbdInteractiveAuthentication` are both false), so it fails with
   `Permission denied (publickey)`. The key must arrive by another path: paste
   it over the Tailscale shell, `curl` it from GitHub, or — best — declare it
   in `users.users.frank.openssh.authorizedKeys.keys` in `modules/users.nix`.
   A public key is not a secret, so the declarative form does not violate
   contract §6, and doing it *before* install skips this dance entirely.
   Full detail in INSTALL.md §11.
   Note there is **no text editor** on the machine (`environment.defaultPackages`
   is perl/rsync/strace); use `cat >>` or add one.
6. **Router** — set a DHCP reservation for the wired interface. Do **not**
   port-forward anything.
7. **Run the verifier**:
   ```bash
   sudo /opt/palimpsest-system/scripts/verify-contract
   ```
8. **Later, when the stack works** — flip `enableAtBoot` to `true` in
   `modules/containers.nix` and rebuild. Note that `systemctl enable
   palimpsest-stack` does **not** persist on NixOS; it is reverted on the next
   rebuild. The flag in the file is the real switch.

Credentials that belong to the *other* repo and never appear here: Tailscale
auth key, WireGuard/VPN credentials for the download client, usenet provider and
indexer credentials, and the API keys the *arr tools mint for each other.

---

## 6. The test VM

```bash
nix build .#nixosConfigurations.palimpsest.config.system.build.vm
./result/bin/run-palimpsest-vm
```

On a NixOS host, `nixos-rebuild build-vm --flake .#palimpsest` does the same
thing. It is not available on a non-NixOS workstation, hence the `nix build`
form.

It runs in your terminal (no QEMU window). Log in as `root` / `vm` or
`frank` / `vm` — those passwords are VM-only, set in `modules/vm.nix`, and are
never built into the laptop. Quit with `Ctrl-a x`.

`/data` is swapped for a tmpfs in the VM, because the `palimpsest-data` label
does not exist there. Crucially `/data/media` and `/data/torrents` stay on one
filesystem, so the hardlink test still proves what it needs to.

### What to check inside

```bash
id media && id frank && getent group render     # 1500 / 1000 / 303
stat -c '%u %g %a' /data /opt/palimpsest-stack  # 1500 1500 775
ls -la /data                                    # the full tree exists
findmnt /data/transcode                         # tmpfs
systemctl is-enabled palimpsest-stack.service   # must say: disabled
systemctl is-active docker                      # active
systemctl is-enabled sleep.target               # must say: masked
nft list table inet nixos-fw | grep -A3 input-allow   # no bare "tcp dport 22"
touch /data/torrents/x && ln /data/torrents/x /data/media/x && echo HARDLINK OK
```

Or just run the real thing, most of which works in the VM:

```bash
/opt/palimpsest-system/scripts/verify-contract    # if you cloned it in
```

### What the VM CANNOT tell you

Be clear-eyed about this — the VM passing is not the same as the machine
working.

- **VAAPI / QuickSync.** No Intel iGPU is passed through, so there is no
  `/dev/dri/renderD128` and `vainfo` will fail. This is the single most
  important thing to test on real hardware and the VM says nothing about it.
- **The dGPU power state.** No NVIDIA device exists in the VM.
- **The boot loader.** The VM boots via QEMU's direct kernel load, not
  systemd-boot on an ESP, so a broken boot loader config would not show up here.
- **The real `/data` disk**, its label, and its filesystem.
- **Tailscale**, which will start but not be authenticated.
- **Networking specifics** — the r8169 driver, DHCP from your router, and
  whether the firewall rules do the right thing against real LAN clients.
  The ruleset's *syntax* is proven at build time; its *effect* is not.

---

## 7. If it does not boot

In rough order of likelihood.

1. **Dropped to an initrd emergency shell / "waiting for device".** Almost
   certainly `hardware-configuration.nix` — either you did not replace the
   placeholder, or the root UUID is wrong. Boot the installer ISO, mount the
   root filesystem, and compare `blkid` output against the file.
2. **Boots but `/data` is empty.** The `palimpsest-data` label is missing or on
   the wrong partition. `blkid | grep palimpsest-data`. Relabel with
   `e2label /dev/<part> palimpsest-data`. The machine is up and SSH works, so
   fix this remotely.
3. **No SSH.** Was the firewall the problem, or the network? From the console:
   `ip a` (did DHCP give an address?), `systemctl status sshd`,
   `nft list table inet nixos-fw`. Remember 22 is only open from RFC1918
   sources — if your workstation is on a non-RFC1918 address, that is the cause.
4. **Rebuild fails with "conflicting definitions" for `fileSystems."/data"`.**
   Expected; see §2.1. Delete the `/data` block from the generated hardware
   config.
5. **Anything else.** Pick the previous generation from the systemd-boot menu.
   Every rebuild leaves the last 10 bootable, which is the main reason this is a
   NixOS box. Then:
   ```bash
   nixos-rebuild switch --rollback
   ```

Useful once you have any shell at all:

```bash
journalctl -b -p err          # errors from this boot
systemctl --failed            # what did not start
journalctl -u palimpsest-stack -b
```

---

## 8. Salvaged from `x17r2-jellyfin-build.md` before deleting it

Contract v2 §0 forbids keeping pre-contract design docs, because that file
contradicted the contract (UID 1000, `/opt/stack`, tmpfs owned 1000:1000) and
would eventually have misled someone. Most of its content is already
implemented or captured elsewhere:

| From the old doc | Where it lives now |
|---|---|
| BIOS settings table | INSTALL.md §1 |
| Disk layout, transcode tmpfs | INSTALL.md §3, `modules/storage.nix` |
| `intel-media-va-driver-non-free`, `vainfo` | `modules/graphics.nix` (as `intel-media-driver` + `vpl-gpu-rt`) |
| Never-sleep `sed` into logind.conf | `modules/power.nix`, as proper NixOS options |
| dGPU D3cold check | §3.1 above |
| `/data` single-mount + hardlink rationale | `modules/storage.nix`, contract §2 |
| Tailscale + ufw rules | `modules/networking.nix`, contract v2 §5.1 |
| `smartd` | `modules/base.nix` |
| DHCP reservation, no port forwarding | INSTALL.md §12 |

What was **not** captured anywhere else is below. It is all **stack-layer**
work — it belongs to `palimpsest-stack` and this session does not implement it —
but it is recorded here so that deleting the file loses nothing.

### Jellyfin transcode settings (stack layer)

Dashboard → Playback → Transcoding:

- Hardware acceleration: **Video Acceleration API (VAAPI)**
- Device: `/dev/dri/renderD128`
- Enable decode for: H264, HEVC, VP9, AV1
- Enable **Intel Low-Power H.264/HEVC encoder** — materially lower power on
  Alder Lake. This is the setting that depends on HuC being loaded; see §3.2.
- Enable hardware tone mapping (VPP)
- Transcode path: `/transcode` (which is `/data/transcode` on the host — the
  8 GB tmpfs, per contract §2/§4)

### How to tell a real hardware transcode from a silent CPU fallback

This one is worth keeping verbatim, because the failure is silent — VAAPI falls
back to software and everything still "works", just badly.

Start a forced transcode, then on the host:

```bash
sudo intel_gpu_top
```

You want activity on the **Video** and **VideoEnhance** engines. If the CPU
cores light up instead and those engines stay idle, VAAPI fell back to software.
`intel-gpu-tools` is installed by this layer (`modules/graphics.nix`) precisely
so this check is available.

The real goal is to never see that screen: a client that direct-plays (Shield,
recent Google TV, Apple TV + Infuse) means the server just serves bytes.

### Maintenance advice worth keeping (stack layer)

- Pin container image tags rather than `:latest` once the stack is stable.
  Update deliberately, not automatically.
- Back up `/opt/palimpsest-stack/*/config` (restic or similar). The media is
  re-acquirable; your users, watch history and *arr configuration are not.
- Recyclarr is worth adding later to keep quality profiles in sync with the
  TRaSH guides.
