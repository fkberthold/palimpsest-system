# =============================================================================
# VM variant — for smoke-testing this config before touching the laptop
#
# Everything in this file applies ONLY to the QEMU test VM. None of it affects
# the real machine: `virtualisation.vmVariant` is a separate evaluation of the
# system that is used solely to build `config.system.build.vm`.
#
# Run it with:
#
#     nix build .#nixosConfigurations.palimpsest.config.system.build.vm
#     ./result/bin/run-palimpsest-vm
#
# (On a NixOS host you can use `nixos-rebuild build-vm --flake .#palimpsest`
# instead, which produces the same thing. That command is not available on a
# non-NixOS workstation, hence the `nix build` form above.)
#
# WHAT THE VM CAN AND CANNOT TELL YOU is written up in NOTES.md. Read it — the
# VM proves quite a lot, but it CANNOT prove the two things most likely to go
# wrong on the real hardware (VAAPI and the dGPU power state), because the VM
# has no Intel iGPU to pass through.
# =============================================================================
{ lib, ... }:

{
  virtualisation.vmVariant = {
    # -------------------------------------------------------------------------
    # VM resources
    # -------------------------------------------------------------------------
    virtualisation = {
      memorySize = 4096; # MB. Enough to start docker and the tmpfs.
      cores = 2;
      diskSize = 8192; # MB of virtual root disk.

      # Run in the terminal you launched it from rather than opening a QEMU
      # graphics window. This is a headless config; testing it headlessly is
      # the point.
      graphics = false;

      # SSH into the VM from the host: `ssh -p 2222 frank@localhost`.
      # Note this will be REFUSED by password, because the real config sets
      # PasswordAuthentication = false — which is itself worth confirming.
      forwardPorts = [
        {
          from = "host";
          host.port = 2222;
          guest.port = 22;
        }
      ];
    };

    # -------------------------------------------------------------------------
    # Credentials — VM ONLY
    # -------------------------------------------------------------------------
    # Contract §6 forbids credentials in this repo, and that is about the real
    # machine. These exist so you can log in at the VM's console, they are
    # visible to anyone reading this file, and they are never built into the
    # laptop's system. Do not copy this pattern out of this block.
    users.users.root.initialPassword = "vm";
    users.users.frank.initialPassword = "vm";

    # -------------------------------------------------------------------------
    # Storage: stand in for the physical /data disk
    # -------------------------------------------------------------------------
    # The real config mounts /data from /dev/disk/by-label/palimpsest-data. That
    # label does not exist in the VM, so without this override the VM would boot
    # with /data missing (the `nofail` option means it would boot, but /data
    # would be an empty directory on the root filesystem and every /data check
    # would fail confusingly).
    #
    # Substituting a tmpfs keeps the important property intact: /data/media and
    # /data/torrents remain on ONE filesystem, so the hardlink test in
    # scripts/verify-contract exercises the same code path it will on the real
    # box and genuinely proves something.
    #
    # mkForce is required because the real definition in modules/storage.nix is
    # a normal (unprioritised) definition; without mkForce the two would be a
    # conflict rather than an override.
    fileSystems."/data" = lib.mkForce {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [
        "size=2G"
        "mode=0775"
        "uid=1500"
        "gid=1500"
      ];
    };

    # /data/transcode needs no override — it is already a tmpfs in the real
    # config and behaves identically here.

    # -------------------------------------------------------------------------
    # Boot loader
    # -------------------------------------------------------------------------
    # The VM boots directly via QEMU's kernel loading rather than through
    # systemd-boot on a virtual ESP. Disabling this avoids the VM needing an EFI
    # system partition it does not have.
    #
    # CONSEQUENCE WORTH KNOWING: this means the VM does NOT test the boot loader
    # configuration. If systemd-boot is misconfigured, the VM will not catch it;
    # the first time you find out is on the real machine. That is a known and
    # accepted gap, listed in NOTES.md.
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  };
}
