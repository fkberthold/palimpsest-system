# =============================================================================
# palimpsest — top-level machine definition
#
# This file does almost nothing by itself. It is a table of contents: it pulls
# in the hardware description and each feature module, and sets the handful of
# values that are genuinely machine-identity rather than feature configuration.
#
# If you are looking for a specific behaviour, it is in one of the modules
# listed under `imports` below, not here.
# =============================================================================
{ ... }:

{
  imports = [
    # Machine-specific, generated on the target. See the warning in that file.
    ./hardware-configuration.nix

    # Feature modules, each self-contained and heavily commented.
    ../../modules/base.nix # boot, locale, nix daemon, admin tooling, sshd
    ../../modules/users.nix # contract §1 — identity, UIDs, GIDs
    ../../modules/graphics.nix # contract §4 — QuickSync / VAAPI
    ../../modules/power.nix # never sleep; keep the dGPU asleep
    ../../modules/storage.nix # contract §2 — /data and the directory tree
    ../../modules/containers.nix # contract §3 — Docker + the stack unit
    ../../modules/networking.nix # contract §5 — firewall, tailscale
  ];

  networking.hostName = "palimpsest";
  time.timeZone = "America/New_York";

  # ---------------------------------------------------------------------------
  # State version — DO NOT CHANGE THIS LATER
  # ---------------------------------------------------------------------------
  # This is not "which NixOS version am I running". It records which release's
  # *default data layouts* this machine was first built against, so that later
  # upgrades don't silently migrate e.g. a database directory out from under a
  # running service.
  #
  # It stays at the value it was installed with, forever, even after you upgrade
  # the machine to 26.11 and beyond. Changing it to match a newer release is a
  # classic way to break things.
  system.stateVersion = "26.05";
}
