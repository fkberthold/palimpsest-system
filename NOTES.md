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
service that runs `scripts/verify-contract` at boot, and ran it under KVM. Final
result: **30 passed, 0 failed, 4 informational** (the informational ones are the
GPU checks, which no VM can pass). So the following are observed behaviour on a
running system, not predictions:

- `media` 1500/1500, `frank` 1000, `render` 303, `media` shell = `nologin`
- `/data`, `/opt/palimpsest-stack` and the whole media tree created by
  systemd-tmpfiles at `1500 1500 775`
- `/data/transcode` mounted as tmpfs with the right ownership
- all five sleep targets **masked**; `HandleLidSwitch=ignore` present in the
  generated `logind.conf`
- docker running; `palimpsest-stack.service` present and **not** started at boot
- nftables table loaded with the RFC1918 rule in it
- **the hardlink test passes** — `/data/torrents` → `/data/media`, same inode

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

### 3.1 The dGPU might not reach D3cold — GENUINELY UNVERIFIED

`modules/power.nix` blacklists `nouveau` and installs no NVIDIA driver, so
nothing binds to the card. **That guarantees no driver is loaded. It does not
guarantee D3cold.**

An unbound PCIe device only drops to D3cold if the parent root port's runtime
power management and the ACPI `_PR3` power resources cooperate, and on
Dell/Alienware firmware that has historically varied by model and BIOS version.
I could not verify this without the hardware, and prompt 1 asked me to say so
rather than guess.

Measure it:

```bash
lspci -Dnn | grep -i nvidia                          # get the address
cat /sys/bus/pci/devices/0000:01:00.0/power_state    # want D3cold
```

If it says `D0`, escalating options, cheapest first:

1. Confirm BIOS graphics mode is **Hybrid/Optimus**, not discrete-only. In
   discrete-only the iGPU is off and QuickSync is gone entirely — you would
   have noticed, but check anyway.
2. Check the root port allows runtime PM:
   `cat /sys/bus/pci/devices/0000:00:01.0/power/control` (should be `auto`).
3. Only then consider `boot.kernelParams`. **Do not start here** — guessing PCIe
   power parameters on a laptop is a good way to produce a machine that does not
   resume from anything, and this one is not supposed to sleep anyway.

Worst case it costs 10–15 W continuously and breaks nothing. Do not let it block
the install.

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

## 4. Contract observations — flagged, not worked around

Prompt 1 said to stop and tell you rather than change a contract value or route
around it. Two things.

### 4.1 Contract gap: DLNA discovery ports

Contract §5 says Jellyfin runs on host networking *because* that is "required
for DLNA and client auto-discovery" — but the port table then lists only TCP
8096 for Jellyfin.

Auto-discovery does not run on 8096. It needs **UDP 1900** (SSDP) and **UDP
7359** (Jellyfin's own discovery broadcast). With the firewall exactly as
specified, inbound discovery probes from LAN clients are dropped, so
auto-discovery will not work. Host networking gets Jellyfin the ability to
*send*, not to *receive*.

Clients pointed explicitly at the server's address work perfectly, which is how
most people use Jellyfin — so this may well be fine. **I did not add the ports.**
If you want discovery, amend contract §5 first, then add to
`modules/networking.nix`:

```
ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } udp dport { 1900, 7359 } accept
```

### 4.2 A port is open that contract §5's table does not list: UDP 41641

`services.tailscale.openFirewall = true` opens **UDP 41641** on all interfaces.
This is Tailscale's own transport, not an application port, which is why it is
not in the §5 table — but it *is* an inbound port on a default-deny box, so you
should know it is there.

Without it, Tailscale still works, but peer traffic falls back to relaying
through a DERP server — slow for streaming video, and impolite to Tailscale's
infrastructure. Nothing is port-forwarded at the router, so this is only
reachable from your LAN in practice. Set `openFirewall = false` if you would
rather have the relay.

### 4.3 One deliberate under-implementation

Contract §3 specifies the stack unit's ordering as `After=docker.service`. I
implemented exactly that. A stricter `Requires=docker.service` would be
defensible — as written, if docker is somehow not running the unit starts and
fails rather than pulling docker in — but the contract says ordering, and
quietly upgrading it is not mine to do. Failing loudly is a reasonable behaviour
regardless.

### 4.4 The old build doc is stale

`x17r2-jellyfin-build.md` disagrees with `contract.md`: it creates `media` at
UID **1000**, mounts the transcode tmpfs `uid=1000,gid=1000`, and puts the stack
at `/opt/stack`. The contract says 1500/1500 and `/opt/palimpsest-stack`.
**I followed the contract everywhere.** Worth correcting or deleting that doc so
a future session does not follow it.

---

## 5. What you must do by hand

No secrets are in this repo (contract §6). These are the steps that need a
human.

1. **BIOS first**, per `x17r2-jellyfin-build.md` §1 — that part is still
   correct. Especially: graphics mode **Hybrid/Optimus** (discrete-only kills
   QuickSync), AC power recovery **on**, Secure Boot **off**.
2. **Root password** — `nixos-install` prompts for one at the end. That is the
   only credential created during install.
3. **First console login.** SSH has `PasswordAuthentication = false` and `frank`
   has **no password and no key** — deliberately, so nothing credential-shaped
   lives in git. On first boot, log in as `root` at the laptop's own keyboard:
   ```bash
   passwd frank
   ```
4. **Install your SSH key**, from your workstation:
   ```bash
   ssh-copy-id frank@<lan-ip>      # will prompt for the password you just set
   ```
   Then confirm key auth works before you walk away from the machine.
   Optionally afterwards, add the key to `users.users.frank` in
   `modules/users.nix` (a public key is not a secret) so it is declarative.
5. **Tailscale** — authenticate once by hand. No auth key is in the config:
   ```bash
   sudo tailscale up --ssh
   ```
   The node key persists in `/var/lib/tailscale` across reboots and rebuilds.
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
