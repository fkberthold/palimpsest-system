# Prompt 1 — NixOS system layer

Run on your workstation, not the laptop. Attach `contract.md`. Deliverable is a config directory you carry to the target.

---

I am building a NixOS configuration for a headless home media server. I am an experienced software engineer but **I do not know Nix well** — I cannot reliably review your work, so your job is to produce a config I can *trust*, with uncertain parts clearly marked rather than smoothed over.

I have attached `contract.md`. It defines the interface between this configuration and a container stack being built separately. **Every value in it is fixed.** If you think one is wrong, stop and tell me — do not change it and do not work around it.

Your scope is the system layer only. You are not writing the compose file; another session does that.

## Ground rules

1. **Never invent a NixOS option.** Verify against the module source in nixpkgs, `nixos-option`, or search.nixos.org for our pinned release. If you can't verify it, don't use it — leave a `# UNVERIFIED:` comment saying what you intended.
2. **Flag every guess** with `# VERIFY: <what to check and how>`. Twelve honest VERIFY comments beat a clean config that silently doesn't work.
3. **Flakes throughout.** No `<nixpkgs>` angle brackets, no `import <nixpkgs> {}`, no channel-style anything.
4. **Options get renamed between releases and your training data may predate the rename.** `hardware.opengl.*` became `hardware.graphics.*` in 24.11; treat that as representative, not exhaustive. Verify current names for anything graphics-, firmware-, or virtualisation-related.
5. **Boring over clever.** No custom modules, overlays, or derivations unless nothing else works.
6. **Ask me** when a decision depends on facts you don't have.

## Method

Init the `palimpsest-system` repo per contract §0 before writing anything; commit per working milestone. Build in stages — run `nix flake check` and `nixos-rebuild build --flake .#palimpsest` after each, not once at the end. Finish by setting up `nixos-rebuild build-vm --flake .#palimpsest` and telling me how to run it and what to check inside.

## Hardware

Alienware x17 R2 (2022). Hostname `palimpsest`, timezone `America/New_York`, UEFI, systemd-boot.

- **i7-12700H**, Alder Lake, with Iris Xe iGPU — this does all transcoding
- **RTX 3070 Ti mobile** — **no driver, no PRIME, no CUDA.** It should sit in D3cold. If keeping it there needs anything explicit, tell me rather than guessing.
- 32 GB DDR5, 2 TB NVMe (only storage initially)
- **Killer E3100G 2.5 GbE** (Realtek RTL8125, `r8169`) — primary interface, wired
- **Killer AX1675** Wi-Fi 6E (Intel AX211, `iwlwifi`) — needs redistributable firmware, but won't be used

## Build this

**Graphics / QuickSync.** Intel iGPU enabled for VAAPI. We need iHD (`intel-media-driver`), not legacy i965 (`vaapiIntel`). We also need whatever currently provides the oneVPL/QSV runtime — this name has churned (`intel-media-sdk` → `onevpl-intel-gpu` → `vpl-gpu-rt`), so **verify which is right for our pinned release instead of trusting any of those.** Include `vainfo` and `intel-gpu-tools` so I can confirm it works.

**Never sleep.** Lid close ignored on AC and battery. Suspend, hibernate, hybrid-sleep unreachable. Use proper NixOS options (`services.logind.*`, sleep targets), not raw config file drops.

**Storage.** Per the contract: `/data` as a single mountpoint on the NVMe initially, plus the 8 GB tmpfs at `/data/transcode`, plus tmpfiles rules for the directory tree with contract-specified ownership. Structure it so mounting a physical disk at `/data` later is a one-line `fileSystems` change and nothing else moves.

**Users and groups.** Per the contract, with **explicit** UIDs and GIDs — including `render` at 303. Do not let Nix assign any of these dynamically; the container stack hardcodes them.

**Docker and the stack unit.** Enable Docker. Create the systemd unit described in contract §3 — `oneshot`, `RemainAfterExit=yes`, correct ordering, no restart policy, **and shipped disabled** so I can bring the stack up by hand during debugging. The compose file is a plain file at `/opt/palimpsest-stack/compose.yaml` that this config does *not* manage the contents of; just make sure the directory exists with the right ownership and the unit points at it.

**Networking and firewall.** Wired-first. Default-deny inbound. Implement contract §5 exactly: LAN (RFC1918 only) gets 22 and 8096; everything else is `tailscale0`-only. Enable Tailscale as a service with **no auth key** in the config.

**Claude Code on the box.** NixOS has no FHS, so the curl-piped native installer won't run — use the nixpkgs package. Verify: (a) that `claude-code` exists in our pinned release and its attribute path, (b) whether it's unfree and needs an allowlist entry, (c) whether the stable version is too old to be useful — if so, propose pulling *only that package* from unstable via a second flake input. **Do not move the whole system to unstable.**

**Also:** `services.openssh` with password auth off, `services.smartd`, `hardware.enableRedistributableFirmware`, and admin tooling (git, tmux, htop, ripgrep, curl, pciutils, usbutils, smartmontools, rsync).

## Out of scope

No secrets anywhere — see contract §6. Placeholders only, documented in `NOTES.md`. Also: do not write the compose file, do not choose container images, do not configure Jellyfin or the automation tools.

## Deliverables

1. `flake.nix`, nixpkgs pinned to a specific stable release (say which and why).
2. `configuration.nix`, split into modules if long, heavily commented for a reader who doesn't know Nix.
3. `hardware-configuration.nix` as a clearly-marked **placeholder** — it must be generated on the real machine. Note how the placeholder differs from what I'll generate and which of your settings could conflict with the generated file.
4. `NOTES.md`: every VERIFY item, what you're least confident about, what I must do by hand, what to check first if it doesn't boot.
5. An ordered checklist for the laptop: boot minimal ISO, partition, generate hardware config, merge, install, first boot, verify.
6. A script or command list implementing the contract §7 verification checks, so I can confirm the contract holds before the other half is even installed.

Start by telling me your plan and any questions, before writing files.
