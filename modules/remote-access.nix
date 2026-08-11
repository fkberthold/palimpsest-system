# =============================================================================
# Remote access for the Roku: contract §5.3
#
# One person outside the house watches this server on a Roku. A Roku has no
# VPN client, so the path is a router port-forward, and the contract
# constrains that path to one shape:
#
#   internet -> router 443 -> nginx (TLS ends here) -> 127.0.0.1:8096 Jellyfin
#
# Three properties this file exists to hold:
#
#   1. 443 is the only STANDING forward at the router. The ACME proof runs
#      over DNS (DNS-01 through DuckDNS), not HTTP, so port 80 stays closed.
#      8443 (below) is forwarded only during deliberate break-glass windows
#      and the router keeps no forward for it the rest of the time.
#   2. Jellyfin stays plaintext and LAN-only on 8096. The proxy reaches it
#      over loopback. The internet never does.
#   3. A scanner that arrives by bare IP gets a dropped TLS handshake, not a
#      Jellyfin banner (the rejectSSL catch-all below, on both TLS ports).
#      Only a client that asks for the DuckDNS name by SNI reaches a proxy.
#
# THE BREAK-GLASS PORT: 8443 is Jellyseerr behind the same TLS front. It
# exists because Jellyseerr is Docker-published, and per contract §5.2 a
# Docker-published port has no host-firewall layer at all: a router forward
# straight to 5055 would go live the moment it was saved, plaintext, carrying
# the Jellyfin admin password. This vhost is the same convenience with TLS.
#
# The switch is the ROUTER FORWARD, by design. This machine always answers
# 8443 (the LAN can already reach 5055 directly, so nothing new is granted),
# and the internet reaches it only while a router forward for 8443 exists.
# The procedure:
#
#   open:   Xfinity admin -> add port forward TCP 8443 -> palimpsest
#   use:    https://vvovv.duckdns.org:8443
#   close:  delete the forward. Do not leave it standing: Jellyseerr sits
#           behind Jellyfin sign-in with no MFA, and the standing posture
#           for it is LAN-only (contract §5.3 break-glass clause).
#
# The name and the credential:
#
#   - The public name is a DuckDNS subdomain. A systemd timer re-asserts the
#     WAN address every five minutes, so a Comcast address change heals in
#     minutes instead of on the next reboot.
#   - The DuckDNS token is the one credential this feature needs, and per
#     contract §6 it does not live in this repo. Both lego and the updater
#     read it from /var/lib/secrets/duckdns.env (root-owned, mode 0600,
#     created by hand). NOTES.md §5 has the step.
#
# The firewall rule that lets 443 in lives in modules/networking.nix with
# every other INPUT rule. This file contains no firewall rule on purpose:
# one file owns the ruleset, and that property has caught real defects.
# =============================================================================
{ pkgs, ... }:

let
  # The DuckDNS subdomain, without the .duckdns.org suffix.
  duckdnsName = "vvovv";
  fqdn = "${duckdnsName}.duckdns.org";

  # Contract §6: the token stays out of git. Created by hand per NOTES.md §5.
  # Format:  DUCKDNS_TOKEN=<token>
  duckdnsEnv = "/var/lib/secrets/duckdns.env";
in
{
  # ---------------------------------------------------------------------------
  # DuckDNS updater: keep the name pointed at this house
  # ---------------------------------------------------------------------------
  # Comcast residential addresses hold for months and then move without notice
  # (a modem swap, a long outage). The Roku carries the DuckDNS name, so the
  # name is what has to stay correct, and this timer is what keeps it correct.
  # An empty ip= means "the address this request came from", and curl -4 pins
  # that to the IPv4 path the router forward actually serves.
  systemd.services.duckdns-update = {
    description = "Point the DuckDNS name at the current WAN address";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
      EnvironmentFile = duckdnsEnv;
    };
    # DuckDNS answers a bare "OK" or "KO". Treat anything but OK as a failure,
    # so a revoked token shows up in `systemctl status duckdns-update` instead
    # of quietly leaving the name stale.
    script = ''
      response="$(${pkgs.curl}/bin/curl -4 -fsS --max-time 30 \
        "https://www.duckdns.org/update?domains=${duckdnsName}&token=''${DUCKDNS_TOKEN}&ip=")"
      if [ "$response" != "OK" ]; then
        echo "DuckDNS update failed: $response" >&2
        exit 1
      fi
    '';
  };

  systemd.timers.duckdns-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      RandomizedDelaySec = "30s";
    };
  };

  # ---------------------------------------------------------------------------
  # The certificate: ACME over DNS-01
  # ---------------------------------------------------------------------------
  # DNS-01 rather than HTTP-01, and the reason is the contract, not taste:
  # HTTP-01 needs the internet to reach port 80, which means forwarding a
  # second port, and §5.3 says 443 only. lego proves control by writing a TXT
  # record through the DuckDNS API, with the same token the updater uses.
  #
  # group = "nginx" hands key read access to its one consumer. On first
  # activation nginx starts against a self-signed placeholder and swaps to the
  # real certificate when lego lands it, so a missing token file degrades to
  # a cert warning, never a machine that will not boot.
  security.acme = {
    acceptTerms = true;
    defaults.email = "frank@crossnokaye.com";
    certs.${fqdn} = {
      dnsProvider = "duckdns";
      environmentFile = duckdnsEnv;
      group = "nginx";
    };
  };

  # ---------------------------------------------------------------------------
  # nginx: the only thing the internet talks to
  # ---------------------------------------------------------------------------
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    # The catch-all, and it does real work: default_server plus
    # ssl_reject_handshake. A scanner sweeping the IPv4 space connects with no
    # SNI (or the wrong SNI) and the handshake dies before any certificate or
    # banner goes out. Shodan learns "a TLS port", not "a Jellyfin". The Roku
    # asks for the name, so it never lands here. The explicit listen list is
    # what extends the same treatment to the break-glass port: without it,
    # 8443's only server block would be the Jellyseerr vhost, and a bare-IP
    # scan during an open window would complete a handshake there.
    virtualHosts."reject-by-default" = {
      default = true;
      rejectSSL = true;
      listen = [
        { addr = "0.0.0.0"; port = 443; ssl = true; }
        { addr = "[::]"; port = 443; ssl = true; }
        { addr = "0.0.0.0"; port = 8443; ssl = true; }
        { addr = "[::]"; port = 8443; ssl = true; }
      ];
    };

    virtualHosts.${fqdn} = {
      forceSSL = true;
      useACMEHost = fqdn;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8096";
        # Jellyfin moves play-state and remote control over a websocket.
        # Without the Upgrade headers the video still plays and the session
        # quietly loses live features, which is the worst kind of breakage.
        proxyWebsockets = true;
        # A buffering proxy spools video to disk while the client seeks.
        # Off is what Jellyfin's own nginx sample ships.
        extraConfig = ''
          proxy_buffering off;
        '';
      };
    };

    # The break-glass vhost: Jellyseerr on 8443, same name, same certificate
    # (a certificate names a host, not a port). Procedure and rationale in the
    # header comment. A separate attrset from the vhost above because one
    # NixOS vhost cannot serve different upstreams on different ports.
    virtualHosts."jellyseerr-breakglass" = {
      serverName = fqdn;
      onlySSL = true;
      useACMEHost = fqdn;
      listen = [
        { addr = "0.0.0.0"; port = 8443; ssl = true; }
        { addr = "[::]"; port = 8443; ssl = true; }
      ];
      locations."/" = {
        # The stack publishes Jellyseerr on the LAN address (contract §5.2),
        # so that address is the only door nginx can knock on. This is the one
        # place the system layer writes the house's address, and it holds the
        # same value as BIND_ADDR_LAN in the stack's .env. If the reservation
        # ever moves, both move.
        proxyPass = "http://10.0.0.155:5055";
        proxyWebsockets = true;
      };
    };
  };
}
