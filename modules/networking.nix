# =============================================================================
# Networking and firewall — contract §5
#
# The shape of the policy, in one sentence: nothing is reachable from the
# internet, a very short list is reachable from the house, and everything else
# is reachable only over Tailscale.
#
# Contract v2 §5.1, implemented literally:
#
#   port          service                      reachable from
#   ------------  ---------------------------  -----------------
#   22/tcp        SSH                          LAN + tailscale0
#   8096/tcp      Jellyfin                     LAN + tailscale0
#   1900,7359/udp Jellyfin client discovery    LAN only
#   5055/tcp      Jellyseerr                   LAN + tailscale0
#   6767/tcp      Bazarr                       tailscale0 only
#   7878/tcp      Radarr                       tailscale0 only
#   8080/tcp      qBittorrent WebUI            tailscale0 only
#   8081/tcp      SABnzbd                      tailscale0 only
#   8989/tcp      Sonarr                       tailscale0 only
#   9696/tcp      Prowlarr                     tailscale0 only
#   41641/udp     Tailscale transport          all interfaces (disclosed, §5.1)
#
# Nothing is port-forwarded from the router, ever. Jellyfin has no rate limiting
# and no MFA and is not built to sit on the open internet.
#
# ---------------------------------------------------------------------------
# READ THIS BEFORE "FIXING" AN UNREACHABLE ADMIN UI — contract v2 §5.2
# ---------------------------------------------------------------------------
# For everything Docker PUBLISHES, the rules in this file are the SECOND layer,
# not the first.
#
# Docker publishes ports by DNAT in PREROUTING, which never traverses the INPUT
# chain where this firewall lives. A container published on 0.0.0.0 is reachable
# from the LAN no matter what any rule below says. Exposure for published
# services is controlled primarily by the stack's BIND ADDRESS
# (`BIND_ADDR_TAILNET` / `BIND_ADDR_LAN` in palimpsest-stack), which defaults to
# 127.0.0.1 so an unconfigured stack fails closed.
#
# So if an admin UI is unreachable, the bind address is the near-certain cause
# and OPENING A PORT HERE WILL NOT FIX IT — it will just widen the firewall
# while leaving the actual problem in place. Check the stack's bind address
# first. That belongs to the other repo; this session does not edit it.
#
# The one thing these rules ARE solely responsible for: Jellyfin. It runs on
# host networking and is not published by Docker at all, so 8096/1900/7359 are
# protected by this file and nothing else.
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
    # Note this is deliberately a PORT LIST and not
    # `trustedInterfaces = [ "tailscale0" ]`. Trusting the interface would open
    # every port on the machine to the tailnet. The contract enumerates specific
    # ports, so we enumerate specific ports; a device that joins the tailnet
    # later gets access to these services and not to anything else running here.
    interfaces."tailscale0".allowedTCPPorts = [
      22 # SSH
      5055 # Jellyseerr
      6767 # Bazarr
      7878 # Radarr
      8080 # qBittorrent WebUI
      8081 # SABnzbd
      8096 # Jellyfin
      8989 # Sonarr
      9696 # Prowlarr
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
    # TCP 5055 (Jellyseerr) is in the LAN rule as of contract v2. It is the
    # family-facing request UI; confining it to the tailnet, as v1 did, put it
    # out of reach of the people it exists for.
    #
    # UDP 1900/7359 are Jellyfin client auto-discovery — SSDP and Jellyfin's own
    # broadcast. They are LAN-ONLY and deliberately absent from the tailscale0
    # port list: discovery is a broadcast mechanism that does not work across a
    # tailnet anyway, so opening them there would be pure surface for no
    # function. Without these, host networking lets Jellyfin *send* discovery
    # traffic but inbound probes are dropped, so clients silently have to be
    # pointed at an IP by hand.
    extraInputRules = ''
      ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport { 22, 8096, 5055 } accept comment "contract v2 §5.1: SSH + Jellyfin + Jellyseerr from LAN (RFC1918) only"
      ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } udp dport { 1900, 7359 } accept comment "contract v2 §5.1: Jellyfin client auto-discovery, LAN only"
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
  # Resolved in contract v2 — kept as a record of why these rules exist
  # ---------------------------------------------------------------------------
  # Two things this module flagged against contract v1 were amended rather than
  # worked around, and are now implemented above:
  #
  #   - UDP 1900/7359 were missing, so the auto-discovery that v1 used to
  #     justify host networking could not actually work. Now in the LAN rule.
  #   - UDP 41641 was open but undocumented. Now disclosed in §5.1 and in the
  #     table at the top of this file.
  #
  # Nothing here is outstanding against the contract.
}
