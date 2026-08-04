# CLAUDE.md — palimpsest-system

Orientation for a future session working in this repo. Read this before
changing anything.

## What this repo is

The **system layer** of `palimpsest`, a headless home media server built on an
Alienware x17 R2 (2022) given a second life. NixOS, flakes, one machine.

It owns: boot, drivers, users, filesystems, networking, firewall, and the
systemd unit that launches the container stack.

It does **not** own: `compose.yaml`, container images, or any application
configuration. Those belong to `palimpsest-stack` at `/opt/palimpsest-stack`.

## The repo boundary is hard — do not cross it

Per contract §0: **a session working in this repo does not edit
`palimpsest-stack`, and vice versa.** If the stack needs a firewall port opened
or a UID changed, it stops and says so rather than reaching across.

This is deliberate. These sessions run with permissions skipped, and a boundary
an agent cannot cross is worth more than the convenience of crossing it.

## `contract.md` is the source of truth and you may not change it

`contract.md` is the interface both halves are built against, currently at
**version 3 (2026-08-04)**. **No value in it may be changed by an agent.** If you
believe one is wrong, stop and say so — v2 and v3 both exist because conflicts
were flagged rather than worked around, and Frank amended the contract. v3 in
particular corrected a defect in v2 that *both* halves had faithfully
implemented: a contract can be wrong, and trusting it is not a defence.

Contract §0 also forbids committing pre-contract design docs. `x17r2-jellyfin-build.md`
was deleted for contradicting the contract; anything still useful from it is in
NOTES.md §8. Do not reintroduce it.

Values this repo implements, all fixed:

| | |
|---|---|
| `frank` | uid 1000 |
| `media` | uid 1500, gid 1500 — the shared service account every container runs as |
| `render` | gid **303**, pinned explicitly rather than inherited |
| `/data` | single filesystem, `media:media`, `0775` |
| `/data/transcode` | 8 GB tmpfs |
| `/opt/palimpsest-stack` | `media:media`, `0775` |
| VAAPI | iHD (`intel-media-driver`), **never** legacy i965 |
| Firewall | default-deny. **Host-bound services only:** 22 + 8096 from RFC1918 and from `tailscale0`; UDP 1900/7359 LAN only; 41641/udp all interfaces (disclosed). Docker-published ports appear nowhere — see §5.2 below. |

`scripts/verify-contract` checks all of it on a live machine. Run it after any
change that touches identity, storage, or the firewall.

## Layout

```
flake.nix                                  pinned to nixos-26.05
hosts/palimpsest/configuration.nix         table of contents; identity + stateVersion
hosts/palimpsest/hardware-configuration.nix  MACHINE-SPECIFIC, generated. Not portable.
modules/base.nix                           boot, locale, nix, sshd, smartd, admin tools
modules/users.nix                          contract §1 — every UID/GID
modules/graphics.nix                       contract §4 — QuickSync/VAAPI
modules/power.nix                          never sleep; keep the dGPU asleep
modules/storage.nix                        contract §2 — /data, tmpfs, tmpfiles tree
modules/containers.nix                     contract §3 — Docker + the stack unit
modules/networking.nix                     contract §5 — nftables firewall, tailscale
modules/vm.nix                             test-VM overrides ONLY; no effect on real machine
scripts/verify-contract                    contract §7 checks
INSTALL.md                                 ordered install checklist
NOTES.md                                   VERIFY items, uncertainties, manual steps
```

`hardware-configuration.nix` is committed but is **machine-specific and not
portable**. It is regenerated per machine by `nixos-generate-config`.

## Deliberate decisions — do not "fix" these

- **`/data` is defined in `modules/storage.nix`, not in the hardware config,**
  and is addressed **by label** (`palimpsest-data`). Both so that moving the
  library to a physical disk later needs no edit here, and so regenerating the
  hardware config never clobbers it.
- **`/data` uses `nofail`.** On a headless laptop, an unmountable `/data` must
  not strand the box in an initrd shell. Safe because the stack unit carries
  `RequiresMountsFor=/data` and so cannot start without it.
- **`services.openssh.openFirewall = false`.** It defaults to *true* and merges
  port 22 into `allowedTCPPorts`, which silently opens SSH on every interface,
  contrary to contract §5. Do not remove that line.
- **nftables backend.** Required: `allowedTCPPorts` cannot express "RFC1918
  sources only", so the LAN rule is raw nft in `extraInputRules`.
- **The stack unit ships disabled** via `enableAtBoot` in
  `modules/containers.nix`. `systemctl enable` does **not** persist on NixOS.
- **`After=`, not `Requires=`, on docker/tailscaled.** Contract v3 §3 specifies
  ordering. Failing loudly when a dependency is missing is wanted, and this was
  confirmed correct on review. Do not "strengthen" it.
- **The stack unit has NO restart policy while `enableAtBoot = false`, and
  gains one when it is `true`** (`Restart=on-failure`, `RestartSec=30`,
  `StartLimitIntervalSec=600`, `StartLimitBurst=5`). Not a contradiction of the
  per-container recovery rule: that rule stops systemd fighting Docker over
  *running* containers; this covers a unit that **never started** (e.g. the
  tailscale0 poll timing out at boot), where no container exists for Docker to
  recover. `StartLimit*` must be in `unitConfig` — systemd reads them from
  `[Unit]`, and in `[Service]` they are ignored, giving an unbounded loop.
- **The stack unit's `ExecStartPre` waits for `tailscale0` to have an IPv4
  address and FAILS after 60s.** The stack binds admin UIs to the tailnet
  address and Docker cannot bind an address that does not exist. Ordering after
  `tailscaled.service` is not sufficient — the daemon going active does not mean
  the interface has an address. On an unauthenticated node this fails by design;
  run `tailscale up` first.
- **`/data/transcode` is in `RequiresMountsFor`** even though nothing breaks
  without it. If the tmpfs fails to mount, the directory underneath still works,
  and Jellyfin silently transcodes to the NVMe — the exact write wear this
  design exists to prevent. Nothing else catches that.
- **No `virtualisation.oci-containers`.** It would move the service list across
  the repo boundary into this repo.
- **One nixpkgs input.** `claude-code` in 26.05 is current (2.1.187), so no
  second unstable input was needed. Do not add one casually.
- **No credential anywhere** (contract §6) — no password, no auth key. The VM
  passwords in `modules/vm.nix` are VM-only and never reach the laptop.

## Before you add a firewall port — READ THIS

Contract v3 §5.2. **For a Docker-published port there is no host-firewall layer
at all.** Not a weaker one, not a second one. None.

Docker DNATs published ports in `PREROUTING`; the destination is rewritten to
the container before the packet reaches `INPUT`, which is the chain this
firewall lives in. The packet is then forwarded, and this config does not filter
forwarding either (`networking.firewall.filterForward` is left at its default
`false` — verified). A rule here naming a published port is not weak, it is
**never consulted**.

So the rules in `modules/networking.nix` exist for exactly one category:
**services that bind on the host.** Today that is sshd (22) and host-networked
Jellyfin (8096, 1900, 7359). Nothing else. Everything Docker publishes is
governed solely by its bind address (`BIND_ADDR_TAILNET` / `BIND_ADDR_LAN` in
`palimpsest-stack`) — the other repo's file, which **this session does not
edit**. Report the problem instead.

Consequences:

- An admin UI that is unreachable is a **bind address** problem. Adding a port
  here cannot fix it and only widens the firewall.
- An admin UI reachable **when it should not be** is also a bind address
  problem. No rule here can close it.
- **THE ONE PATH BACK:** if a service ever moves from Docker publishing to host
  networking, it stops being covered by its bind address and starts needing a
  rule here. **Add it at that time.** That is the only circumstance in which the
  port lists in `modules/networking.nix` should grow.

Contract v3 removed 5055 *and* the six admin-UI ports (6767, 7878, 8080, 8081,
8989, 9696) from this layer for exactly this reason — under v2 they sat in the
RFC1918 rule and the `tailscale0` list, read as protection, and constrained
nothing. **Do not restore them.** Removing an inert rule changed real exposure
by zero packets; what it removed was a false belief.

This layer cannot verify Docker-published exposure at all. The check with teeth
is contract §7.2's listener scan, run after stack bring-up:
`ss -ltnp | awk '$4 !~ /^\[/ {print $4}' | sort -u` — no published port may show
`0.0.0.0:` or `*:`.

## Known-fragile areas

1. **dGPU D3cold is unverified.** `nouveau` is blacklisted, which guarantees no
   driver binds — it does *not* guarantee D3cold. See NOTES.md §3.1. Costs
   10–15 W if it fails; breaks nothing.
2. **GuC/HuC firmware** for Jellyfin's low-power encoder is probably enabled by
   default on this kernel but was not confirmed. NOTES.md §3.2.
3. **Option names churn between releases.** `hardware.opengl.*` is gone;
   `services.logind.extraConfig` is removed and `lidSwitch` is only a renamed
   alias; `vaapiIntel` and `onevpl-intel-gpu` do not exist. **Verify against the
   pinned nixpkgs, not from memory.**
4. **`mkVMOverride` beats `mkForce`** in `modules/vm.nix`. VM filesystems must go
   through `virtualisation.fileSystems`; a `fileSystems` + `mkForce` override is
   silently discarded with no error. See the comment in that file.
5. **An inert rule is worse than no rule.** v2 put 5055 in the RFC1918 rule and
   six admin-UI ports on `tailscale0`; all were Docker-published, so `INPUT`
   never saw them. They passed review, passed a ruleset grep, and passed the
   verifier — while constraining nothing. When adding any rule here, first ask
   whether traffic to that port actually reaches `INPUT`.
6. **`nixpkgs.config` must not reference `pkgs`.** `allowUnfreePredicate` in
   `modules/base.nix` takes `lib` from the module arguments. Reaching back
   through `pkgs.lib` is circular by construction — `nixpkgs.config` is an input
   to building `pkgs` — and happens to terminate only by accident of evaluation
   order.

## Working here

```bash
nix flake check                                          # evaluates + builds + nft --check
nix build .#nixosConfigurations.palimpsest.config.system.build.toplevel
nix build .#nixosConfigurations.palimpsest.config.system.build.vm && ./result/bin/run-palimpsest-vm
sudo nixos-rebuild switch --flake /opt/palimpsest-system#palimpsest   # on the machine
```

`nix flake check` runs `nft --check` on the generated firewall ruleset as part of
the build, so a passing build is real evidence the firewall will load. That
matters on a headless box: a broken ruleset means no SSH.

**Flakes ignore untracked files.** `git add` new files or Nix will not see them.
