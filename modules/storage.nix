# =============================================================================
# Storage — contract §2
#
# The single most important property in this whole configuration is stated in
# contract §2 and it is worth restating here, because nothing will warn you when
# it breaks:
#
#     /data MUST BE ONE FILESYSTEM.
#
# Sonarr/Radarr import completed downloads by HARDLINKING from /data/torrents
# into /data/media. A hardlink cannot cross a filesystem boundary. If you ever
# mount a second disk at, say, /data/media, the tools do not error out — they
# silently fall back to copying. You then pay double the disk space for every
# file and seeding breaks, and you find out months later.
#
# The tmpfs at /data/transcode is the sole permitted exception, because nothing
# ever hardlinks into it.
# =============================================================================
{ config, ... }:

let
  # Pulled from the user definitions rather than retyped, so that these two
  # numbers can only ever have one source of truth. Contract §1 fixes them at
  # 1500/1500; see modules/users.nix.
  mediaUid = toString config.users.users.media.uid;
  mediaGid = toString config.users.groups.media.gid;
in
{
  # ---------------------------------------------------------------------------
  # /data — the one line you change to move the library to a real disk
  # ---------------------------------------------------------------------------
  # Prompt 1 asked that relocating /data onto a physical disk later be a
  # one-line change and nothing else. That is why this lives here and NOT in
  # hardware-configuration.nix: regenerating the hardware config on the target
  # must never rewrite this.
  #
  # It is addressed BY LABEL, not by UUID, and that is the thing that makes the
  # future migration cheap. A UUID is minted by mkfs and is different on every
  # new disk, so a UUID here would have to be edited every time. A label is
  # chosen by you. To move the library to a new disk:
  #
  #     mkfs.ext4 -L palimpsest-data /dev/<new-disk>
  #
  # ...and this file does not change at all.
  #
  # The cost of labels: if two attached filesystems ever carry the same label,
  # which one wins is not defined. Do not reuse this label on a backup disk.
  #
  # THE INSTALLER MUST CREATE THIS LABEL. See the install checklist in NOTES.md;
  # `mkfs.ext4 -L palimpsest-data` is a required step, not an optional nicety.
  fileSystems."/data" = {
    device = "/dev/disk/by-label/palimpsest-data";
    fsType = "ext4";

    # `nofail` is a deliberate choice for a HEADLESS machine, and it is a
    # trade-off worth understanding.
    #
    # Without nofail, a missing or corrupt /data drops the boot into an initrd
    # emergency shell. On a laptop wedged on a shelf with no monitor attached,
    # that means the box is simply gone until you carry a screen to it.
    #
    # With nofail, the machine boots, SSH comes up, and you can diagnose it
    # remotely. The obvious worry — that the container stack would then happily
    # write to an empty /data directory on the root filesystem — is handled in
    # modules/containers.nix, where the stack unit carries
    # `RequiresMountsFor=/data` and therefore refuses to start at all unless the
    # real filesystem is mounted.
    #
    # So: boot succeeds, stack stays down, you get a shell. That is the correct
    # failure mode for this machine.
    options = [
      "defaults"
      "nofail"
    ];
  };

  # ---------------------------------------------------------------------------
  # /data/transcode — 8 GB tmpfs (contract §2 and §4)
  # ---------------------------------------------------------------------------
  # Jellyfin writes transcoding segments here. Putting it in RAM removes what is
  # otherwise by far the largest source of NVMe write wear on a media server:
  # a single 2-hour transcode can write several GB that is deleted minutes
  # later. With 32 GB installed, 8 GB is affordable.
  #
  # `size=8G` is a CEILING, not a reservation — tmpfs only consumes the RAM
  # actually in use, so this costs nothing while idle.
  #
  # Ownership is set in the mount options rather than by tmpfiles, because a
  # tmpfs is created fresh and empty on every single boot; whatever the mount
  # says is what you get. Contract §2 requires media:media 0775.
  fileSystems."/data/transcode" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [
      "defaults"
      "size=8G"
      "mode=0775"
      "uid=${mediaUid}"
      "gid=${mediaGid}"
      # Transcode segments are data, never programs. Refusing execution and
      # setuid here costs nothing and removes a writable-and-executable
      # directory from a box that runs internet-facing services.
      "noexec"
      "nosuid"
      "nodev"
    ];
  };

  # ---------------------------------------------------------------------------
  # The directory tree — contract §2
  # ---------------------------------------------------------------------------
  # systemd-tmpfiles creates these on every boot if missing and, importantly,
  # CORRECTS their ownership and mode if something has changed them. That makes
  # the contract's "1500:1500, 0775" self-healing rather than a one-time chown
  # you have to remember to redo.
  #
  # Rule format:  d  <path>  <mode>  <user>  <group>  <age>
  #   d  = create directory if absent, then enforce mode/ownership
  #   -  = no age-based cleanup (never auto-delete anything in here)
  #
  # NOTE these are NOT recursive. Only the listed directories have their
  # ownership enforced; files the *arr apps create underneath keep whatever
  # ownership they were created with, which is what the compose UMASK=002 and
  # PUID/PGID settings are for. Contract §1 covers that half.
  systemd.tmpfiles.rules = [
    # Parent of the stack checkout. Left root-owned: it is not media data.
    "d /opt 0755 root root -"

    # Contract §3 — the compose file and per-app config subdirectories live
    # here. The containers write into it as media:media, hence 0775 and not
    # root-owned. This config deliberately does NOT manage the contents; the
    # palimpsest-stack repo owns everything inside.
    "d /opt/palimpsest-stack 0775 media media -"

    # Contract §2 — the media tree. Every path below is on the single /data
    # filesystem, which is what makes hardlinking work.
    "d /data 0775 media media -"

    "d /data/media 0775 media media -"
    "d /data/media/movies 0775 media media -"
    "d /data/media/tv 0775 media media -"

    "d /data/torrents 0775 media media -"
    "d /data/torrents/movies 0775 media media -"
    "d /data/torrents/tv 0775 media media -"

    "d /data/usenet 0775 media media -"
    "d /data/usenet/incomplete 0775 media media -"
    "d /data/usenet/complete 0775 media media -"

    # /data/transcode is a tmpfs and its ownership comes from the mount options
    # above. This rule is a harmless backstop: if the tmpfs ever fails to mount,
    # the directory still exists with the right ownership rather than the
    # transcode landing in a root-owned hole.
    "d /data/transcode 0775 media media -"
  ];
}
