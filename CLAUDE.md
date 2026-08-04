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

`contract.md` is the interface both halves are built against. **No value in it
may be changed by an agent.** If you believe one is wrong, stop and say so.

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
| Firewall | default-deny; 22 + 8096 from RFC1918 only; everything else `tailscale0` only |

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
- **No `Restart=` on the stack unit.** Per-container `restart: unless-stopped`
  owns recovery; two layers restarting each other thrash.
- **No `virtualisation.oci-containers`.** It would move the service list across
  the repo boundary into this repo.
- **One nixpkgs input.** `claude-code` in 26.05 is current (2.1.187), so no
  second unstable input was needed. Do not add one casually.
- **No credential anywhere** (contract §6) — no password, no auth key. The VM
  passwords in `modules/vm.nix` are VM-only and never reach the laptop.

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
5. **Contract gap: DLNA discovery** needs UDP 1900/7359, which contract §5 does
   not list. Flagged in NOTES.md §4.1, deliberately not implemented.

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
