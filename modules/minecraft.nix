# =============================================================================
# The Minecraft server's system side, contract v6
#
# Everything the system layer owes palimpsest-minecraft lives in this one file:
# its directories, the backup drive, its firewall rules and the unit that runs
# its compose project. The game, its backups and its panel are the
# palimpsest-minecraft repo's business, the same way the media services belong
# to palimpsest-stack.
#
# Firewall rules and tmpfiles entries merge with the ones in networking.nix and
# storage.nix, so nothing here edits those files.
# =============================================================================
{
  config,
  lib,
  pkgs,
  ...
}:

let
  mcDir = "/opt/palimpsest-minecraft";
  composeFile = "${mcDir}/compose.yaml";
  docker = "${config.virtualisation.docker.package}/bin/docker";

  # The same default-route gate as the stack unit in containers.nix, copied
  # rather than shared so this file stands alone. The panel binds
  # BIND_ADDR_LAN itself, and that address doesn't exist until the DHCP lease
  # lands. See containers.nix for why it tests a route and not an address.
  waitForNetwork = pkgs.writeShellScript "minecraft-wait-for-lan-address" ''
    for i in $(seq 1 60); do
      ${pkgs.iproute2}/bin/ip -4 route list default 2>/dev/null | grep -q '^default' && exit 0
      sleep 1
    done
    echo "no default IPv4 route after 60s. The LAN is not up, so the panel cannot bind." >&2
    exit 1
  '';

  # Contract section 3 ships units disabled until the service is shown to
  # work. Flip this once the server has been played on, the same way the
  # stack's flag was flipped. A manual `systemctl enable` is reverted by the
  # next rebuild, so this is the only switch that sticks.
  #
  # Enabled 2026-10-10, after a night of play on the new box, the panel
  # running, and a restore drill that passed.
  enableAtBoot = true;
in
{
  # ---------------------------------------------------------------------------
  # Directories, contract section 2
  # ---------------------------------------------------------------------------
  # Not recursive, like the rules in storage.nix. The server writes its own
  # files underneath as media:media.
  systemd.tmpfiles.rules = [
    "d ${mcDir} 0775 media media -"
    "d /data/minecraft 0775 media media -"
    "d /data/minecraft/server 0775 media media -"
  ];

  # ---------------------------------------------------------------------------
  # The backup drive, contract section 2
  # ---------------------------------------------------------------------------
  # A separate USB SSD, deliberately outside /data so it can't break the
  # single-filesystem rule there. `nofail` lets the box boot with the drive
  # unplugged, and the short device timeout keeps a missing drive from
  # stalling boot for the default 90 seconds.
  #
  # An unmounted /mnt/mc-backup is an empty folder on the root disk. The
  # backup job checks for the marker file .mc-backup-drive before it writes
  # anything, which is what keeps restic from filling root in that case.
  fileSystems."/mnt/mc-backup" = {
    device = "/dev/disk/by-uuid/b4a177ac-77aa-4613-9251-bbf853b1aecd";
    fsType = "ext4";
    options = [
      "nofail"
      "x-systemd.device-timeout=10s"
      "noatime"
      "nosuid"
      "nodev"
      "noexec"
    ];
  };

  # ---------------------------------------------------------------------------
  # Firewall, contract sections 5.1 to 5.3
  # ---------------------------------------------------------------------------
  # All three Minecraft containers run on host networking, so these rules are
  # the enforcement and not decoration (contract 5.2).
  #
  # 25565 accepts any source because the players are outside the house. The
  # router forward alone can't expose it. This rule has to exist too, which is
  # the property 5.3 keeps.
  #
  # 8765 is the panel. It drives Docker, so it's LAN only and never forwarded.
  #
  # 25575 (RCON) gets no rule at all. The backup job and the panel reach it on
  # 127.0.0.1, and default-deny drops it from everywhere else.
  networking.firewall.extraInputRules = ''
    tcp dport 25565 accept comment "contract v6 §5.3: Minecraft, internet via standing router forward. Host-networked, so this rule is the gate"
    ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport 8765 accept comment "contract v6 §5.1: Minecraft panel, LAN (RFC1918) only, never forwarded"
  '';

  # ---------------------------------------------------------------------------
  # The unit, contract section 3
  # ---------------------------------------------------------------------------
  # A copy of palimpsest-stack.service in containers.nix. Read the comments
  # there for the reasoning behind each line. Only the differences are
  # explained here.
  systemd.services.palimpsest-minecraft = {
    description = "palimpsest Minecraft server (docker compose)";
    documentation = [ "file://${composeFile}" ];

    after = [
      "docker.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];

    # /mnt/mc-backup is left out on purpose. The game should keep running with
    # the backup drive unplugged, and the marker check in the backup job
    # handles a missing drive.
    unitConfig = {
      RequiresMountsFor = [
        "/data"
        mcDir
      ];
    }
    // lib.optionalAttrs enableAtBoot {
      StartLimitIntervalSec = 600;
      StartLimitBurst = 5;
    };

    wantedBy = lib.optional enableAtBoot "multi-user.target";

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = mcDir;
      ExecStartPre = waitForNetwork;
      ExecStart = "${docker} compose -f ${composeFile} up -d";
      ExecStop = "${docker} compose -f ${composeFile} down";

      # The first start builds Spigot from source with BuildTools, which takes
      # several minutes on top of the image pulls.
      TimeoutStartSec = 0;
      TimeoutStopSec = 300;
    }
    // lib.optionalAttrs enableAtBoot {
      Restart = "on-failure";
      RestartSec = 30;
    };
  };
}
