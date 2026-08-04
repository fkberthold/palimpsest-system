# =============================================================================
#                    ####  P L A C E H O L D E R  ####
#
#   THIS FILE IS A FAKE. IT WILL NOT BOOT THE REAL MACHINE.
#
#   Every UUID below is invented so the configuration can be *evaluated* on a
#   workstation. None of them exist on your laptop. Booting with this file
#   in place drops you at an initrd emergency shell.
#
#   You must replace it wholesale on the target, during install:
#
#       nixos-generate-config --root /mnt
#       cp /mnt/etc/nixos/hardware-configuration.nix \
#          /mnt/opt/palimpsest-system/hosts/palimpsest/hardware-configuration.nix
#
#   THEN READ "Merging the generated hardware config" IN NOTES.md BEFORE
#   REBUILDING. The generated file will contain entries that collide with
#   modules/storage.nix, and you have to delete them by hand. This is the single
#   most likely thing to go wrong during install.
# =============================================================================
{ lib, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # ---------------------------------------------------------------------------
  # What the real generated file will differ on
  # ---------------------------------------------------------------------------
  # `availableKernelModules` is what initrd loads in order to *find* the root
  # filesystem. The real list is detected from your hardware. `nvme` and the
  # usb/keyboard entries below are near-certain for this laptop, but do not
  # hand-edit this list — let nixos-generate-config produce it.
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "thunderbolt"
    "nvme"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # ---------------------------------------------------------------------------
  # Filesystems — ALL FAKE UUIDs
  # ---------------------------------------------------------------------------
  # Note what is and is not here. Only `/` and `/boot` live in this file.
  #
  # `/data` and `/data/transcode` are deliberately defined in
  # modules/storage.nix instead, so that regenerating this file never touches
  # them and relocating /data to a physical disk later is a one-line edit in a
  # file that means something. See contract §2.
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/0000-0000";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  # No disk swap by design — zram instead. See modules/base.nix.
  swapDevices = [ ];

  # Per-interface DHCP defaults; the generated file sets these too. mkDefault
  # means modules/networking.nix can override without a conflict.
  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # i7-12700H — microcode updates. The generated file will set this itself.
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;
}
