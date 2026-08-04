# =============================================================================
# Networking and firewall — contract §5
#
# The shape of the policy, in one sentence: nothing is reachable from the
# internet, a very short list is reachable from the house, and everything else
# is reachable only over Tailscale.
#
# Contract §5, implemented literally:
#
#   port  service            reachable from
#   ----  -----------------  -----------------
#     22  SSH                LAN + tailscale0
#   8096  Jellyfin           LAN + tailscale0
#   5055  Jellyseerr         tailscale0 only
#   6767  Bazarr             tailscale0 only
#   7878  Radarr             tailscale0 only
#   8080  qBittorrent WebUI  tailscale0 only
#   8081  SABnzbd            tailscale0 only
#   8989  Sonarr             tailscale0 only
#   9696  Prowlarr           tailscale0 only
#
# Nothing is port-forwarded from the router, ever. Jellyfin has no rate limiting
# and no MFA and is not built to sit on the open internet.
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
    extraInputRules = ''
      ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport { 22, 8096 } accept comment "contract §5: SSH + Jellyfin from LAN (RFC1918) only"
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
  # ⚠ CONTRACT GAP — flagged, NOT worked around. Read this.
  # ---------------------------------------------------------------------------
  # Contract §5 says Jellyfin runs on host networking because that is "required
  # for DLNA and client auto-discovery" — but the port table then lists only TCP
  # 8096 for Jellyfin.
  #
  # Client auto-discovery does not run on 8096. It needs:
  #     UDP 1900   SSDP  (DLNA discovery)
  #     UDP 7359         (Jellyfin's own client auto-discovery broadcast)
  #
  # With the firewall as specified, host networking will get Jellyfin the
  # ability to *send* discovery traffic, but inbound discovery probes from LAN
  # clients will be dropped, so auto-discovery will not work. Clients that are
  # pointed at the server's address explicitly will be entirely fine, which is
  # how most people use Jellyfin anyway.
  #
  # I have NOT added these ports, because contract §5 is fixed and adding them
  # is your call, not mine. If you decide auto-discovery matters, the change is
  # to amend contract §5 and then add here:
  #
  #     ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } \
  #       udp dport { 1900, 7359 } accept
  #
  # See NOTES.md, "Contract gap: DLNA discovery ports".
}
