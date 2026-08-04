# =============================================================================
# Power behaviour — never sleep, and keep the dGPU asleep
#
# Two unrelated goals that happen to both be about power:
#   1. The machine is a server in a laptop chassis. Closing the lid, or any idle
#      timer, must never suspend it.
#   2. The RTX 3070 Ti must stay powered down. It is worth 10-15 W continuous.
# =============================================================================
{ ... }:

{
  # ---------------------------------------------------------------------------
  # 1a. logind: ignore the lid
  # ---------------------------------------------------------------------------
  # OPTION NAME WARNING, and this one will bite any guide you read:
  # `services.logind.lidSwitch` still "works" in 26.05 but only as a renamed
  # alias that emits a deprecation warning. `services.logind.extraConfig` is
  # REMOVED outright and fails to evaluate.
  #
  # The canonical form in this release is settings.Login.<systemd key name>,
  # verified against nixos/modules/system/boot/systemd/logind.nix.
  #
  # These are the same keys the Debian-flavoured notes would sed into
  # logind.conf by hand — but this is the proper NixOS option, not a config-file
  # drop, so it survives rebuilds and shows up in the config you can diff.
  services.logind.settings.Login = {
    # Lid closed on battery.
    HandleLidSwitch = "ignore";
    # Lid closed on AC — the normal case for this box, which lives on AC.
    HandleLidSwitchExternalPower = "ignore";
    # Lid closed while docked. Set for completeness so no path is left open.
    HandleLidSwitchDocked = "ignore";
  };

  # ---------------------------------------------------------------------------
  # 1b. Make sleep genuinely unreachable
  # ---------------------------------------------------------------------------
  # Ignoring the lid stops the most likely trigger. This stops all the others,
  # including `systemctl suspend` typed by a tired admin at 2am, and any future
  # package that decides to schedule a sleep.
  #
  # In NixOS, `systemd.targets.<name>.enable = false` symlinks the unit to
  # /dev/null — i.e. it MASKS it, exactly as `systemctl mask` would. Verified in
  # nixos/lib/systemd-lib.nix. A masked target cannot be started by anything,
  # which is the "unreachable" the brief asked for.
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
    # Not named in the brief, but it is a fifth door into the same room.
    suspend-then-hibernate.enable = false;
  };

  # There is also no hibernation possible even in principle: there is no disk
  # swap device for a hibernation image to be written to (modules/base.nix uses
  # zram only). That is a happy consequence of the swap decision, not the
  # mechanism we rely on.

  # ---------------------------------------------------------------------------
  # 2. Keep the NVIDIA dGPU powered down
  # ---------------------------------------------------------------------------
  # Contract §4: NVIDIA is not installed and not configured; the dGPU stays in
  # D3cold. The BIOS must be in Hybrid/Optimus mode, NOT discrete-only — that
  # part matters a great deal, because discrete-only mode disables the iGPU and
  # QuickSync disappears entirely.
  #
  # What this config does: installs no NVIDIA driver (there is no
  # `hardware.nvidia` anywhere in this repo, and `services.xserver.videoDrivers`
  # is untouched), and blacklists the open-source `nouveau` driver so that
  # nothing binds to the card at boot.
  boot.blacklistedKernelModules = [
    "nouveau"
    # The proprietary modules are not packaged into this system at all, so these
    # entries are inert. They cost nothing and make the intent unambiguous to a
    # future reader who is wondering whether NVIDIA was forgotten or excluded.
    "nvidia"
    "nvidia_drm"
    "nvidia_modeset"
  ];

  # VERIFY / KNOWN-UNCERTAIN — read NOTES.md before trusting this.
  #
  #   Blacklisting nouveau guarantees no driver binds to the card. It does NOT
  #   by itself guarantee D3cold. An unbound PCIe device only drops to D3cold if
  #   the parent root port's runtime power management and the ACPI _PR3 power
  #   resources cooperate, and on Dell/Alienware firmware that has historically
  #   been model- and BIOS-version-dependent.
  #
  #   I am NOT asserting this works. Measure it on the real machine:
  #
  #       lspci -nn | grep -i nvidia                            # find the address
  #       cat /sys/bus/pci/devices/0000:01:00.0/power_state     # want D3cold
  #
  #   (0000:01:00.0 is the conventional address for the dGPU on this chassis,
  #   but confirm with lspci rather than assuming.)
  #
  #   If it reports D0 instead, do not start guessing kernel parameters — the
  #   fallback options and their trade-offs are written up in NOTES.md under
  #   "The dGPU might not reach D3cold".
}
