# =============================================================================
# Container runtime and the stack unit — contract §3
#
# THE DIVIDING LINE BETWEEN THE TWO REPOS RUNS THROUGH THIS FILE.
#
# This module guarantees three things and nothing more:
#   1. Docker is installed and running.
#   2. /opt/palimpsest-stack exists with the right ownership (modules/storage.nix).
#   3. A systemd unit exists that runs whatever compose.yaml it finds there.
#
# It does NOT know or care what is in compose.yaml. That file is a plain file on
# disk owned by the palimpsest-stack repo — deliberately NOT in the Nix store,
# because it is the thing that changes most often and requiring a nixos-rebuild
# per tweak would make the iteration loop miserable (contract §3).
#
# The practical consequence: editing compose.yaml needs no rebuild. Changing how
# the stack is *launched* needs a rebuild. That is the seam.
# =============================================================================
{ config, lib, ... }:

let
  stackDir = "/opt/palimpsest-stack";
  composeFile = "${stackDir}/compose.yaml";

  # The docker CLI, by absolute store path. systemd units get almost no PATH, so
  # every ExecStart must name its binary in full.
  docker = "${config.virtualisation.docker.package}/bin/docker";

  # ---------------------------------------------------------------------------
  #  >>> THE ONE LINE YOU FLIP WHEN THE STACK IS READY <<<
  # ---------------------------------------------------------------------------
  # Contract §3: "Enabled at boot: No, initially. Ships disabled; I enable it
  # once the stack works."
  #
  # READ THIS BEFORE REACHING FOR `systemctl enable` — on NixOS that will NOT do
  # what you expect. Unit enablement is derived from this configuration on every
  # rebuild, so a manual `systemctl enable palimpsest-stack` gets silently
  # reverted the next time you run nixos-rebuild. The knob is here, in git,
  # instead. That is a feature: the boot behaviour of the machine is a thing you
  # can read, diff and revert.
  #
  # While it is `false` you still bring the stack up by hand, and that works
  # exactly as you would want during debugging:
  #
  #     sudo systemctl start palimpsest-stack     # up -d
  #     sudo systemctl stop  palimpsest-stack     # down
  #     sudo systemctl status palimpsest-stack
  #     journalctl -u palimpsest-stack -f
  #
  # When you are happy, change this to `true`, rebuild, and it comes up at boot.
  enableAtBoot = false;
in
{
  # ---------------------------------------------------------------------------
  # Docker
  # ---------------------------------------------------------------------------
  virtualisation.docker = {
    enable = true;

    # Daemon starts at boot regardless of whether the stack unit does, so that
    # `docker ps` and manual `docker compose` work on a freshly booted box.
    enableOnBoot = true;

    # Deliberately NOT enabling autoPrune. It would garbage-collect unused
    # images on a timer, which sounds tidy right up until it removes the last
    # known-good image of a service you just broke. Container updates on this
    # box are meant to be deliberate, not automatic.
  };

  # Docker images and volumes land in /var/lib/docker, i.e. on the root
  # filesystem, NOT on /data. That is intentional — /data is for media, and
  # keeping the container layer store off it means a full library disk cannot
  # wedge the container runtime. Budget for it when sizing root; the install
  # checklist allocates 100 GB.

  # ---------------------------------------------------------------------------
  # The stack unit — contract §3
  # ---------------------------------------------------------------------------
  systemd.services.palimpsest-stack = {
    description = "palimpsest container stack (docker compose)";
    documentation = [ "file://${composeFile}" ];

    # Contract §3: After=docker.service.
    #
    # Note this is ORDERING ONLY, per the contract, not a dependency: if docker
    # is somehow not running, this unit will start and fail loudly rather than
    # pulling docker in. Failing visibly is the intended behaviour. (Adding
    # `requires = [ "docker.service" ]` would be defensible, but the contract
    # specifies ordering and I do not get to quietly upgrade it. See NOTES.md.)
    after = [ "docker.service" ];

    # Contract §3 again, and this is what makes the `nofail` on /data safe.
    #
    # RequiresMountsFor turns each path into a dependency on the mount unit that
    # provides it. If /data did not mount, this unit does not start — so the
    # stack can never write media into an empty directory sitting on the root
    # filesystem, which would silently break every hardlink in the system.
    unitConfig.RequiresMountsFor = [
      "/data"
      stackDir
    ];

    # Ships disabled. See the long comment on `enableAtBoot` above.
    wantedBy = lib.optional enableAtBoot "multi-user.target";

    serviceConfig = {
      # Contract §3: oneshot + RemainAfterExit.
      #
      # `docker compose up -d` returns as soon as the containers are started —
      # it is not a long-running foreground process, so this is not a `simple`
      # service. RemainAfterExit=yes makes systemd treat the unit as "active"
      # after that command exits, which is what lets `systemctl stop` fire
      # ExecStop and bring the stack down.
      Type = "oneshot";
      RemainAfterExit = true;

      WorkingDirectory = stackDir;

      # Contract §3: `docker compose up -d` on start, `down` on stop.
      ExecStart = "${docker} compose -f ${composeFile} up -d";
      ExecStop = "${docker} compose -f ${composeFile} down";

      # NOT contract-specified, but necessary in practice: the default start
      # timeout for a oneshot unit is 90 seconds, and the very first `up -d`
      # has to PULL every image in the stack. On a home connection that is
      # comfortably more than 90 seconds, and the unit would be killed
      # mid-pull, leaving a half-started stack and a confusing failure.
      #
      # 0 means "no limit". The unit is started by hand or at boot, never on a
      # timer, so there is nothing here to pile up.
      TimeoutStartSec = 0;

      # Stopping is bounded: containers get their normal grace period, and if
      # something hangs we still finish the shutdown rather than blocking a
      # reboot forever.
      TimeoutStopSec = 300;
    };

    # Contract §3: "Unit restart policy: None. Per-container
    # `restart: unless-stopped` handles recovery."
    #
    # There is deliberately no Restart= here. Two layers both trying to restart
    # things fight each other: systemd would re-run `up -d` underneath a docker
    # daemon that is already restarting individual containers, and you get
    # thrashing that is very hard to read in the journal. Recovery belongs to
    # docker, per-container, in the stack repo's compose.yaml.
  };

  # ---------------------------------------------------------------------------
  # What this module deliberately does NOT do
  # ---------------------------------------------------------------------------
  # - It does not use `virtualisation.oci-containers`. That option would put
  #   container definitions into the Nix store and generate one systemd unit per
  #   container, which is a perfectly good pattern but is NOT the one the
  #   contract specifies, and it would move ownership of the service list across
  #   the repo boundary into this repo.
  # - It does not create /opt/palimpsest-stack/<appname>/ config directories.
  #   Those are per-app runtime state owned by the stack repo (contract §0), and
  #   docker creates them on first run as needed.
  # - It does not write, template, validate or read compose.yaml.
}
