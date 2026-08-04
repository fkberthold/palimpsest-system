# =============================================================================
# Base system — boot, locale, the nix daemon itself, admin tooling, sshd
#
# Nothing in here is media-server-specific. This is the "make it a usable,
# maintainable Linux box" layer.
# =============================================================================
{ lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # Boot
  # ---------------------------------------------------------------------------
  # UEFI + systemd-boot, per the hardware brief. systemd-boot is the boring
  # choice here: no GRUB config language, and NixOS generations appear in the
  # boot menu automatically so a bad rebuild is recoverable by picking the
  # previous entry.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Keep 10 generations in the boot menu. Without a limit the ESP eventually
  # fills up, which fails a rebuild at the worst possible moment.
  boot.loader.systemd-boot.configurationLimit = 10;

  # Headless: don't wait around at the boot menu.
  boot.loader.timeout = 3;

  # ---------------------------------------------------------------------------
  # Swap: zram only
  # ---------------------------------------------------------------------------
  # Compressed swap in RAM. There is no disk swap and no hibernation (see
  # modules/power.nix), so this exists purely to give the kernel somewhere to
  # put cold pages under transcode pressure instead of OOM-killing something.
  # 25% of 32 GB = up to 8 GB of compressed swap, which costs no NVMe writes.
  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };

  # ---------------------------------------------------------------------------
  # Locale
  # ---------------------------------------------------------------------------
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  # ---------------------------------------------------------------------------
  # Nix daemon
  # ---------------------------------------------------------------------------
  nix.settings = {
    # Required for `nixos-rebuild --flake` to work on the machine itself.
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # Deduplicate identical files in the store. Saves real space over time.
    auto-optimise-store = true;
  };

  # Garbage-collect weekly. Without this the store grows without bound as you
  # rebuild. 30 days keeps enough history to roll back a bad change.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # ---------------------------------------------------------------------------
  # Unfree packages
  # ---------------------------------------------------------------------------
  # NixOS refuses to build unfree software unless you say so explicitly. Rather
  # than a blanket `allowUnfree = true`, this allowlists exactly one package by
  # name, so that if some future edit drags in another unfree dependency, the
  # build fails loudly instead of quietly accepting it.
  #
  # claude-code is the only unfree package here (verified against 26.05:
  # meta.license.shortName = "unfree").
  #
  # `lib` comes from the module arguments, NOT from `pkgs.lib`. Both evaluate
  # here, but referencing `pkgs` from inside `nixpkgs.config` is a documented
  # infinite-recursion footgun: `nixpkgs.config` is an *input* to constructing
  # `pkgs`, so reaching back through `pkgs` to fill it in is circular by
  # construction. It happens to terminate in this case because `pkgs.lib` is
  # resolved before the config is forced — which is exactly the kind of
  # accident that stops being true after an unrelated change. The module
  # argument `lib` is the same library with none of that risk.
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];

  # ---------------------------------------------------------------------------
  # Firmware
  # ---------------------------------------------------------------------------
  # Pulls in redistributable blobs. Needed by the Intel AX211 Wi-Fi (iwlwifi)
  # even though we don't intend to use Wi-Fi — without it the driver throws
  # firmware-load errors into the journal on every boot. Also covers assorted
  # Intel GPU firmware.
  hardware.enableRedistributableFirmware = true;

  # ---------------------------------------------------------------------------
  # SSH — the only way in, so this matters
  # ---------------------------------------------------------------------------
  services.openssh = {
    enable = true;

    # ---- DO NOT REMOVE THIS LINE -------------------------------------------
    # `services.openssh.openFirewall` DEFAULTS TO TRUE, and what it does is
    # append port 22 to `networking.firewall.allowedTCPPorts`. That is a
    # separate option definition, so it merges straight past the empty
    # `allowedTCPPorts = [ ]` in modules/networking.nix rather than being
    # overridden by it.
    #
    # The result, which I caught by reading the generated nftables ruleset
    # rather than by reading the config, was a bare
    #
    #     tcp dport { 22 } accept
    #
    # sitting at the top of the input chain — SSH accepted from ANY source on
    # ANY interface. Contract §5 says port 22 is reachable from LAN and
    # tailscale0 only.
    #
    # With this false, port 22 is opened only by the two scoped rules in
    # modules/networking.nix: the RFC1918 source rule and the tailscale0
    # interface rule. Turning it back on silently widens the firewall.
    openFirewall = false;

    settings = {
      # Keys only. See NOTES.md: you get in via the physical console on first
      # boot, set a password for frank, then install your key.
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # ---------------------------------------------------------------------------
  # Disk health
  # ---------------------------------------------------------------------------
  # autodetect = scan every SMART-capable device rather than naming the NVMe by
  # path, so a second disk added later is monitored without a config change.
  services.smartd = {
    enable = true;
    autodetect = true;
  };

  # ---------------------------------------------------------------------------
  # Admin tooling
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    # Requested in prompt 1
    git
    tmux
    htop
    ripgrep
    curl
    pciutils # lspci — needed to check the dGPU power state
    usbutils # lsusb
    smartmontools # smartctl
    rsync

    # Runs on the box itself. NixOS has no FHS, so the curl-piped native
    # installer from claude.ai cannot work here; this is the packaged build.
    claude-code

    # Small quality-of-life additions for a headless box you will be debugging
    # over SSH. Remove any you don't want.
    jq
    tree
    file
    dnsutils # dig, for when "is it DNS" needs answering
  ];
}
