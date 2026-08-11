# =============================================================================
# Networking and firewall — contract §5
#
# The shape of the policy, in one sentence: nothing is reachable from the
# internet, a very short list is reachable from the house, and everything else
# is reachable only over Tailscale.
#
# Network exposure. Every port, where it is reachable from, and — crucially —
# WHAT ACTUALLY ENFORCES THAT:
#
#   port          service                    reachable from   enforced by
#   ------------  -------------------------  ---------------  --------------
#   22/tcp        SSH                        LAN only         THIS FILE
#   443/tcp       nginx, TLS front for       internet         THIS FILE
#                 Jellyfin (contract §5.3)
#   8096/tcp      Jellyfin (host networking) LAN only *       THIS FILE
#   1900,7359/udp Jellyfin discovery         LAN only         THIS FILE
#   5055/tcp      Jellyseerr                 LAN only         bind address
#   6767/tcp      Bazarr                     LAN only         bind address
#   7878/tcp      Radarr                     LAN only         bind address
#   8080/tcp      qBittorrent WebUI          LAN only         bind address
#   8081/tcp      SABnzbd                    LAN only         bind address
#   8989/tcp      Sonarr                     LAN only         bind address
#   9696/tcp      Prowlarr                   LAN only         bind address
#
#   * 8096 itself stays LAN-only and plaintext. The internet path is 443: TLS
#     ends at nginx (modules/remote-access.nix), which reaches Jellyfin over
#     loopback. The router forwards 443 and nothing else. See "THE
#     PORT-FORWARD" below.
#
# THIS FILE IMPLEMENTS ONLY THE ROWS MARKED "THIS FILE" — five of them. The rows
# marked "bind address" belong to the stack repo and appear nowhere below.
#
# NO TAILSCALE. It was removed along with contract v3's tailnet design: the
# person this server exists for uses a Roku, which has no Tailscale or WireGuard
# client, so a VPN-based access model cannot serve the actual requirement. What
# replaced it is plain LAN reachability plus an intended port-forward.
#
# ---------------------------------------------------------------------------
# READ THIS BEFORE ADDING A PORT — contract §5.2
# ---------------------------------------------------------------------------
# For a Docker-published port there is NO host-firewall layer. Not a weak one,
# not a second one — none.
#
# Docker DNATs published ports in PREROUTING. The destination is rewritten to
# the container before the packet reaches INPUT, which is the chain this
# firewall lives in. It is then forwarded, and this config does not filter
# forwarding either (`networking.firewall.filterForward` left at its default
# false). A rule here naming a published port is not weak, it is NEVER
# CONSULTED.
#
# So the rules below cover exactly one category: SERVICES THAT BIND ON THE HOST
# — sshd and host-networked Jellyfin. Everything else is governed solely by the
# address the stack binds it to. That is the other repo's file.
#
#   1. An admin UI unreachable? BIND ADDRESS. Adding a port here cannot fix it.
#   2. An admin UI reachable when it should not be? Also the bind address. No
#      rule here can close it.
#   3. THE ONE PATH BACK: if a service moves from Docker publishing to host
#      networking, it stops being covered by its bind address and starts needing
#      a rule here. Add it AT THAT TIME. That is the only reason this list grows.
#
# ---------------------------------------------------------------------------
# THE PORT-FORWARD: BUILT, contract v4 §5.3
# ---------------------------------------------------------------------------
# A Roku outside the house reaches Jellyfin through it. The risk is accepted
# by the contract, and the shape is the one the contract requires:
#
#   - The router forwards 443 and nothing else. Never 8096 (plaintext), and
#     never 22.
#   - TLS ends at nginx on this machine (modules/remote-access.nix), which
#     reaches Jellyfin over loopback. 8096 never faces the internet, so the
#     viewer's password and session tokens never cross it in the clear.
#   - The certificate comes by DNS-01, so port 80 stays closed too. One port
#     forwarded, one any-source rule below, and they are the same port.
#
# What Jellyfin still does not have is rate limiting and MFA. nginx in front
# narrows the attack surface to TLS handshake plus proxied HTTP, and the
# rejectSSL catch-all keeps bare-IP scanners from ever seeing a banner, but
# the password quality of each Jellyfin account is what guards sign-in.
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
    # listed here would be open on EVERY interface and every source — including,
    # once the router forwards a port, the open internet. Everything this
    # machine exposes is scoped to a source range instead, below.
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ ];

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
    #   7359 } also host networking. Without these, Jellyfin can *send*
    #          discovery traffic but inbound probes are dropped, and every
    #          client in the house has to be pointed at an IP by hand.
    #
    # ---- HOW THE PORT-FORWARD MEETS THESE RULES ----------------------------
    # A forwarded packet arrives here with the ORIGINAL PUBLIC SOURCE ADDRESS.
    # The router rewrites the destination, not the source. So internet traffic
    # matches only the 443 rule below. It cannot match the two RFC1918 rules,
    # falls through everywhere else, and dies on the chain's default policy.
    #
    # That is the fail-closed property §5.3 requires, and it still holds for
    # every port except the one that is meant to answer the internet: forward
    # 8096 or 22 at the router by mistake and the packets still go nowhere.
    # The 443 rule is the deliberate, version-controlled edit that the earlier
    # revisions of this file said internet exposure must cost.
    #
    # TCP 5055 (Jellyseerr) WAS in this rule under contract v2 and was REMOVED
    # in v3. It is Docker-published, so this rule never saw its traffic — the
    # rule passed review, passed a grep of the ruleset, and constrained nothing.
    # Jellyseerr's LAN exposure comes from the stack binding an explicit LAN
    # address. Do not add it back.
    extraInputRules = ''
      ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport { 22, 8096 } accept comment "contract v3 §5.1: SSH + Jellyfin from LAN (RFC1918) only; host-bound services only"
      ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } udp dport { 1900, 7359 } accept comment "contract v3 §5.1: Jellyfin client auto-discovery, LAN only"
      tcp dport 443 accept comment "contract v4 §5.3: the one any-source rule; TLS ends at nginx, which fronts Jellyfin for the outside Roku"
    '';

  };

  # ---------------------------------------------------------------------------
  # History of this file's rules — why they are the shape they are
  # ---------------------------------------------------------------------------
  # v1 → v2: UDP 1900/7359 added (auto-discovery could not work without them,
  #          despite v1 citing it as the reason for host networking); UDP 41641
  #          documented rather than silently open.
  #
  # v2 → v3: TCP 5055 removed from the LAN rule, and 5055 + the six admin-UI
  #          ports removed from the tailnet list. All were Docker-published,
  #          so INPUT never saw their traffic. v2 believed the host firewall
  #          bounded them; it did not. Removing an inert rule does not change
  #          real exposure by one packet — it removes a false belief, which over
  #          a five-year life is the more dangerous of the two.
  #
  # v3 → LAN-only: Tailscale removed entirely, along with the tailscale0 port
  #          list, the reverse-path-filter relaxation that existed only for it,
  #          and UDP 41641. The tailnet could never have served the actual
  #          requirement — a Roku has no VPN client — so it was complexity and
  #          an external account dependency bought nothing. The six admin UIs
  #          become LAN-only, enforced by their bind address, not here.
  #
  # LAN-only → §5.3 built: TCP 443 opened to any source, the first and only
  #          any-source rule this file has carried. It is also the only port
  #          the router forwards, and the two are the same port on purpose.
  #          TLS ends at nginx (modules/remote-access.nix), which reaches
  #          host-networked Jellyfin over loopback. 22 and 8096 keep their
  #          RFC1918 source match, so the fail-closed property survives for
  #          everything except the one port meant to answer the internet.
}
