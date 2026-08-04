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
    # ---- WHY THIS IS `virtualisation.fileSystems` AND NOT `fileSystems` ----
    #
    # This is a genuine trap and I got it wrong the first time. qemu-vm.nix does:
    #
    #     fileSystems = mkIf (cfg.fileSystems != {}) (mkVMOverride cfg.fileSystems);
    #
    # `mkVMOverride` is `mkOverride 10`, and `mkForce` is `mkOverride 50`. Lower
    # number wins, so the VM REPLACES THE ENTIRE `fileSystems` ATTRSET with
    # whatever is in `virtualisation.fileSystems` — and it beats mkForce while
    # doing it.
    #
    # The failure mode is silent and misleading: writing
    # `fileSystems."/data" = lib.mkForce {...}` here produces no error, no
    # warning, and no mount. /data then quietly becomes an ordinary directory on
    # the VM's root disk. I only caught it by booting the VM and running the
    # verifier inside, which reported /data as living on /dev/vda.
    #
    # `virtualisation.fileSystems` is a mkMerge, so these entries are ADDED to
    # the VM's defaults (root disk, 9p store share) rather than replacing them.
    virtualisation.fileSystems = {
      "/data" = {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [
          "size=2G"
          "mode=0775"
          "uid=1500"
          "gid=1500"
        ];
      };

      # Must be restated for the same reason: the real definition in
      # modules/storage.nix is discarded by mkVMOverride along with everything
      # else. Smaller than the real 8 GB because the VM only has 4 GB of RAM.
      "/data/transcode" = {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [
          "size=1G"
          "mode=0775"
          "uid=1500"
          "gid=1500"
          "noexec"
          "nosuid"
          "nodev"
        ];
      };
    };

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
