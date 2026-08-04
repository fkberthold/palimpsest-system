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
{
  config,
  lib,
  pkgs,
  ...
}:

let
  stackDir = "/opt/palimpsest-stack";
  composeFile = "${stackDir}/compose.yaml";

  # The stack unit's start precondition.
  #
  # WHY A PRECONDITION EXISTS AT ALL: the stack binds its services to an
  # EXPLICIT address (contract §5.2 — `BIND_ADDR_LAN`, this machine's
  # DHCP-reserved LAN address), and Docker cannot bind an address that does not
  # exist yet. At boot there is a window where the interface is up but DHCP has
  # not yet returned a lease. Starting `docker compose up -d` inside that window
  # fails with a bind error that reads like a Docker problem and is not one.
  #
  # WHAT CHANGED: this used to poll for an IPv4 on `tailscale0`. Tailscale has
  # been removed — a Roku has no VPN client, so a tailnet could never have
  # served the actual requirement — but the underlying race did not go away
  # with it. It just moved from the tailnet address to the LAN address. So the
  # poll is generalised rather than deleted: wait for a global-scope IPv4 on any
  # real interface.
  #
  # `scope global` is doing real work in that match. It excludes 127.0.0.1 and
  # link-local 169.254.0.0/16 — the latter being exactly what you get when DHCP
  # has FAILED, which is a state we want to keep waiting through rather than
  # treat as success.
  #
  # WHY IT FAILS RATHER THAN GIVING UP QUIETLY: a poll that times out and
  # returns success produces a half-started stack — some containers bound, some
  # not — which presents the next morning as an assortment of unrelated-looking
  # symptoms. Exiting non-zero produces one clear line in the journal instead.
  #
  # 60s is ample for DHCP on a wired link.
  #
  # `ip` is referenced by absolute store path. `seq`/`sleep`/`grep` come from
  # the default PATH NixOS gives every systemd service (coreutils + gnugrep),
  # verified present in the generated unit.
  waitForNetwork = pkgs.writeShellScript "wait-for-lan-address" ''
    for i in $(seq 1 60); do
      ${pkgs.iproute2}/bin/ip -4 -o addr show scope global 2>/dev/null | grep -q 'inet ' && exit 0
      sleep 1
    done
    echo "no global IPv4 address after 60s; stack ports will fail to bind" >&2
    exit 1
  '';

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
  #
  # FLIPPING THIS CHANGES TWO THINGS, not one. As well as making the unit
  # wanted at boot, it switches on the contract v3 §3 restart policy
  # (`Restart=on-failure`, `RestartSec=30`, bounded to 5 attempts per 10
  # minutes). That is deliberate: an unattended boot needs to recover from a
  # slow tailnet by itself, whereas a unit you started by hand should fail in
  # front of you rather than silently retrying while you read the journal.
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

    # Ordering only, not a dependency: if docker is somehow not running, this
    # unit starts and fails loudly rather than pulling it in. Failing visibly is
    # the intended behaviour.
    #
    # network-online.target is the *first half* of the address precondition;
    # the ExecStartPre poll is the second half, because on NixOS that target is
    # weaker than it sounds and does not by itself guarantee a DHCP lease.
    after = [
      "docker.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];

    # Contract v2 §3, and this is what makes the `nofail` on /data safe.
    #
    # RequiresMountsFor turns each path into a dependency on the mount unit that
    # provides it. If /data did not mount, this unit does not start — so the
    # stack can never write media into an empty directory sitting on the root
    # filesystem, which would silently break every hardlink in the system.
    #
    # /data/transcode is listed for a DIFFERENT and less obvious reason, added
    # in contract v2. The tmpfs is not needed for correctness — if it fails to
    # mount, the directory underneath still exists with the right ownership, so
    # everything keeps working. That is exactly the problem: Jellyfin would
    # silently transcode to the NVMe instead of to RAM, which is precisely the
    # write wear this design exists to avoid, and nothing else would catch it.
    unitConfig = {
      RequiresMountsFor = [
        "/data"
        "/data/transcode"
        stackDir
      ];
    }
    // lib.optionalAttrs enableAtBoot {
      # Contract v3 §3 — the rate limit half of the enabled-at-boot restart
      # policy. See the long note on Restart= in serviceConfig below.
      #
      # These live in [Unit], NOT [Service]. systemd moved StartLimitIntervalSec
      # and StartLimitBurst to the [Unit] section in v229; left in [Service]
      # they are parsed but ignored, which would silently give an UNBOUNDED
      # restart loop — the exact opposite of what they are here to do.
      # `unitConfig` is NixOS's [Unit] section, so this is correct placement.
      StartLimitIntervalSec = 600;
      StartLimitBurst = 5;
    };

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

      # Bounded wait for a usable LAN address. Defined and explained in the
      # `let` block at the top of this file. A non-zero exit here aborts the
      # unit before ExecStart runs at all.
      ExecStartPre = waitForNetwork;

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
    }
    // lib.optionalAttrs enableAtBoot {
      # -----------------------------------------------------------------------
      # Contract v3 §3 — restart policy, ONLY when enabled at boot
      # -----------------------------------------------------------------------
      # WHY THIS DOES NOT CONTRADICT "no restart policy; per-container
      # `restart: unless-stopped` handles recovery".
      #
      # That rule is about a specific hazard: systemd and Docker BOTH trying to
      # manage containers that are already running. Two supervisors re-running
      # `up -d` underneath a daemon that is itself restarting containers
      # produces thrashing that is genuinely hard to read in a journal. That
      # hazard is real and this does not reintroduce it.
      #
      # This governs a completely different event: a unit that NEVER STARTED.
      # If the ExecStartPre address poll times out at boot — a slow DHCP lease,
      # a switch still negotiating, the router not yet up after a power cut —
      # the unit fails before `docker compose` runs at all. There are
      # no containers running for Docker's own restart policy to recover,
      # because none were ever created. Without this, the stack simply stays
      # down until a human notices, which on a headless box could be days.
      #
      # So: Docker owns recovery for containers that fell over. systemd owns
      # recovery for a start that never happened. No overlap.
      Restart = "on-failure";
      RestartSec = 30;

      # `Restart = "always"` would be rejected here — systemd does not permit it
      # for Type=oneshot. `on-failure` is permitted and is what we want anyway:
      # a clean `systemctl stop` must stay stopped.
      #
      # Bounded by StartLimitIntervalSec=600 / StartLimitBurst=5 in unitConfig
      # above: five attempts in ten minutes, then it gives up and stays failed.
      # A transiently slow tailnet self-heals; a genuinely broken stack stops
      # and waits for a human instead of looping forever and filling the
      # journal.
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
