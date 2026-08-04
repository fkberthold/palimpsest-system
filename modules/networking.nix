# =============================================================================
# Networking and firewall — contract §5
#
# The shape of the policy, in one sentence: nothing is reachable from the
# internet, a very short list is reachable from the house, and everything else
# is reachable only over Tailscale.
#
# Contract v3 §5.1. Note the "enforced by" column — it is the whole point:
#
#   port          service                    reachable from     enforced by
#   ------------  -------------------------  -----------------  ----------------
#   22/tcp        SSH                        LAN + tailscale0   THIS FILE
#   8096/tcp      Jellyfin (host networking) LAN + tailscale0   THIS FILE
#   1900,7359/udp Jellyfin discovery         LAN only           THIS FILE
#   5055/tcp      Jellyseerr                 LAN + tailscale0   bind address
#   6767/tcp      Bazarr                     tailscale0 only    bind address
#   7878/tcp      Radarr                     tailscale0 only    bind address
#   8080/tcp      qBittorrent WebUI          tailscale0 only    bind address
#   8081/tcp      SABnzbd                    tailscale0 only    bind address
#   8989/tcp      Sonarr                     tailscale0 only    bind address
#   9696/tcp      Prowlarr                   tailscale0 only    bind address
#   41641/udp     Tailscale transport        all interfaces     — (disclosed)
#
# THIS FILE IMPLEMENTS ONLY THE FOUR ROWS MARKED "THIS FILE". The rows marked
# "bind address" are the stack's business and appear nowhere below.
#
# Nothing is port-forwarded from the router, ever. Jellyfin has no rate limiting
# and no MFA and is not built to sit on the open internet.
#
# ---------------------------------------------------------------------------
# READ THIS BEFORE ADDING A PORT — contract v3 §5.2
# ---------------------------------------------------------------------------
# For a Docker-published port there is NO host-firewall layer. Not a weak one,
# not a second one — none.
#
# Docker DNATs published ports in PREROUTING. The destination address is
# rewritten to the container before the packet reaches INPUT, so the packet
# never enters the chain this firewall lives in. It is then forwarded, and this
# config does not filter forwarding either (`networking.firewall.filterForward`
# is left at its default of false). A rule here naming a published port is not
# wrong, it is NEVER CONSULTED.
#
# So the rules below exist for exactly one category: SERVICES THAT BIND ON THE
# HOST. Today that is sshd and host-networked Jellyfin, and nothing else.
# Everything Docker publishes is governed solely by its bind address
# (`BIND_ADDR_TAILNET` / `BIND_ADDR_LAN` in palimpsest-stack). That is the other
# repo's file and this session does not edit it.
#
# Three practical consequences:
#
#   1. An admin UI that is unreachable is a BIND ADDRESS problem. Adding a port
#      here cannot fix it and only widens the firewall.
#   2. An admin UI reachable when it should not be is ALSO a bind address
#      problem. No rule here can close it.
#   3. THE ONE PATH BACK: if a service ever moves from Docker publishing to host
#      networking, it stops being covered by its bind address and starts needing
#      a rule here. Add it AT THAT TIME. This is the only circumstance in which
#      this list should grow.
#
# Contract v3 removed 5055 and the six admin-UI ports from this file for exactly
# this reason. They read as protection and provided none.
# =============================================================================
{ ... }:

{
  # ---------------------------------------------------------------------------
  # Interfaces
  # ---------------------------------------------------------------------------
  # Wired-first, by DHCP, with a reservation set on the router so the address is
  # stable without this machine having to hold an opinion about the house's
  # subnet. `networking.useDHCP` is left at the mkDefault true that
  # hardware-configuration.nix provides, so this works regardless of what the
  # 2.5 GbE interface ends up being named (the Killer E3100G is RTL8125 silicon
  # driven by the in-tree r8169 driver; no out-of-tree module is needed).
  #
  # Wi-Fi is explicitly off. The AX211 firmware is installed via
  # hardware.enableRedistributableFirmware purely so the driver stops logging
  # firmware-load failures — the radio is not meant to carry traffic. Serving
  # media over Wi-Fi from the server side is a bad idea regardless.
  networking.wireless.enable = false;

  # ---------------------------------------------------------------------------
  # Firewall backend
  # ---------------------------------------------------------------------------
  # nftables rather than the legacy iptables backend, and this is a load-bearing
  # choice rather than a fashionable one.
  #
  # NixOS's `allowedTCPPorts` cannot express "only from these source addresses"
  # — it opens a port to every interface and every source. Contract §5 requires
  # source-restricted rules (RFC1918 only), so we need to write a couple of raw
  # rules by hand. On the nftables backend that is the well-supported
  # `extraInputRules` option; on the iptables backend it would mean
  # `extraCommands` with hand-rolled iptables invocations and manual attention
  # to rule ordering. The nftables version is far easier to read and to audit.
  networking.nftables.enable = true;

  networking.firewall = {
    enable = true;

    # Default-deny inbound. These two lists are EMPTY ON PURPOSE: anything
    # listed here would be open on every interface, including the wired LAN
    # interface, which is never what contract §5 asks for. Every port this
    # machine exposes is scoped either to an interface or to a source range,
    # below.
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ ];

    # -------------------------------------------------------------------------
    # Tailscale-only services
    # -------------------------------------------------------------------------
    # Scoped to the tailscale0 interface, so these are reachable from your
    # tailnet and from nowhere else — not from the LAN, not from the internet.
    #
    # THIS LIST IS SHORT ON PURPOSE, AND IT SHRANK IN CONTRACT v3.
    #
    # It contains only services that bind ON THE HOST: sshd, and Jellyfin via
    # host networking. Every admin UI (6767, 7878, 8080, 8081, 8989, 9696) and
    # Jellyseerr (5055) used to be listed here and have been REMOVED, because
    # they are Docker-published and an INPUT rule never sees their traffic — see
    # the §5.2 explanation at the top of this file. Those entries read as
    # protection and provided none.
    #
    # Do not "restore" them. Their exposure is governed by the stack's bind
    # address. If you add a port here, it must be for something that binds on
    # the host itself.
    #
    # Note this is deliberately a PORT LIST and not
    # `trustedInterfaces = [ "tailscale0" ]`. Trusting the interface would open
    # every port on the machine to the tailnet.
    interfaces."tailscale0".allowedTCPPorts = [
      22 # SSH — sshd binds on the host
      8096 # Jellyfin — host networking, not published by Docker
    ];

    # -------------------------------------------------------------------------
    # LAN-reachable services — the source-restricted part
    # -------------------------------------------------------------------------
    # "LAN means RFC1918 only" (contract §5), so this matches the three private
    # address blocks rather than an interface. Matching on source address rather
    # than on "the wired interface" is the stricter reading: if this machine
    # ever picks up a public address on that interface, these rules stop
    # matching instead of quietly exposing SSH to the internet.
    #
    # This is nftables syntax, injected into the input chain of the inet
    # nixos-fw table. `ip saddr` matches IPv4 only, which is correct — RFC1918
    # is an IPv4 concept and there is deliberately no IPv6 equivalent rule here.
    #
    # EVERY PORT IN THESE TWO RULES BINDS ON THE HOST. That is the entire
    # criterion for being here, per contract v3 §5.2.
    #
    #   22   — sshd, a host process
    #   8096 — Jellyfin, host networking, not published by Docker
    #   1900 } Jellyfin client auto-discovery (SSDP + Jellyfin's own broadcast),
    #   7359 } also host networking. LAN-only: discovery is a broadcast
    #          mechanism that does not traverse a tailnet, so putting these on
    #          tailscale0 would be surface with no function. Without them,
    #          Jellyfin can *send* discovery traffic but inbound probes are
    #          dropped, and every client has to be pointed at an IP by hand.
    #
    # TCP 5055 (Jellyseerr) WAS in this rule under contract v2 and was REMOVED
    # in v3. It is Docker-published, so this rule never saw its traffic — the
    # rule passed review, passed a grep of the ruleset, and constrained nothing.
    # Jellyseerr's LAN exposure comes from the stack binding an explicit LAN
    # address. Do not add it back.
    extraInputRules = ''
      ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport { 22, 8096 } accept comment "contract v3 §5.1: SSH + Jellyfin from LAN (RFC1918) only; host-bound services only"
      ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } udp dport { 1900, 7359 } accept comment "contract v3 §5.1: Jellyfin client auto-discovery, LAN only"
    '';

    # -------------------------------------------------------------------------
    # Reverse path filtering
    # -------------------------------------------------------------------------
    # NixOS defaults this to strict. Loose is the setting Tailscale wants:
    # tailnet traffic can legitimately arrive on an interface that is not the
    # one the reply would leave by, and strict filtering silently drops those
    # packets, producing a tailnet that pings but will not carry a TCP session.
    #
    # The NixOS tailscale module only relaxes this automatically when
    # `useRoutingFeatures` is "client" or "both" — and this node is neither a
    # subnet router nor an exit node, so it would otherwise be left strict.
    #
    # Security cost is small on a default-deny box: loose rpfilter still drops
    # packets with source addresses that are unroutable from here entirely.
    checkReversePath = "loose";
  };

  # ---------------------------------------------------------------------------
  # Tailscale
  # ---------------------------------------------------------------------------
  services.tailscale = {
    enable = true;

    # Opens UDP 41641 so peers can establish DIRECT connections. Without it
    # tailscale still works, but traffic falls back to relaying through a DERP
    # server — which for streaming video off this box would be both slow and
    # rude to Tailscale's infrastructure.
    #
    # This default is `false` in nixpkgs, so it genuinely has to be set.
    #
    # 41641/udp is open on ALL interfaces, which is why contract v2 §5.1 lists
    # it explicitly — an undocumented open port on a default-deny box is worse
    # than a documented one. It is Tailscale's transport, not an application
    # port, and nothing is forwarded at the router, so in practice it is only
    # reachable from the LAN.
    openFirewall = true;
  };

  # NO AUTH KEY LIVES HERE — contract §6.
  #
  # The NixOS module can auto-authenticate from `services.tailscale.authKeyFile`,
  # and we deliberately do not use it: that would mean a credential on this
  # machine's disk referenced from a file in this repo. You authenticate once,
  # by hand, on first boot:
  #
  #     sudo tailscale up --ssh
  #
  # ...and the resulting node key persists in /var/lib/tailscale across reboots
  # and rebuilds. It is a one-time manual step by design. See NOTES.md.

  # ---------------------------------------------------------------------------
  # History of this file's rules — why they are the shape they are
  # ---------------------------------------------------------------------------
  # v1 → v2: UDP 1900/7359 added (auto-discovery could not work without them,
  #          despite v1 citing it as the reason for host networking); UDP 41641
  #          documented rather than silently open.
  #
  # v2 → v3: TCP 5055 removed from the LAN rule, and 5055 + the six admin-UI
  #          ports removed from the tailscale0 list. All were Docker-published,
  #          so INPUT never saw their traffic. v2 believed the host firewall
  #          bounded them; it did not. Removing an inert rule does not change
  #          real exposure by one packet — it removes a false belief, which over
  #          a five-year life is the more dangerous of the two.
  #
  # Nothing here is outstanding against contract v3.
}
