# =============================================================================
# Identity — contract §1
#
# EVERY NUMBER IN THIS FILE IS FIXED BY THE CONTRACT. The container stack in
# palimpsest-stack hardcodes them as PUID/PGID/group_add. Changing a number here
# silently breaks file ownership across the whole media library.
#
# Nothing here may be left for Nix to assign dynamically. That is the entire
# point of the file.
# =============================================================================
{ ... }:

{
  # ---------------------------------------------------------------------------
  # Groups
  # ---------------------------------------------------------------------------
  users.groups = {
    # Contract §1 — the shared service group. Everything under /data is owned by
    # media:media, and every container runs as 1500:1500.
    media.gid = 1500;

    # Contract §1 — GID 303, pinned explicitly rather than inherited.
    #
    # 303 is in fact what nixpkgs assigns `render` by default (nixos/modules/
    # misc/ids.nix: `render = 303`), and nixpkgs declares the group as an empty
    # attrset, so setting the gid here fills it in rather than colliding.
    #
    # We pin it anyway, deliberately: the contract requires the value to be
    # stated rather than inherited, so that a future nixpkgs release changing
    # its default would break the build here instead of silently breaking GPU
    # access inside the Jellyfin container.
    render.gid = 303;
  };

  # ---------------------------------------------------------------------------
  # Admin user
  # ---------------------------------------------------------------------------
  users.users.frank = {
    isNormalUser = true;
    uid = 1000; # Contract §1. Pinned, not left to first-normal-user assignment.
    description = "Frank";
    extraGroups = [
      "wheel" # sudo
      "docker" # talk to the docker socket without sudo
      "media" # read/write the library without sudo
    ];

    # ---- SSH key, declared here on purpose --------------------------------
    # A PUBLIC key is not a secret. Contract §6 forbids secrets in the repo and
    # forbids baking passwords or private keys into the world-readable Nix
    # store; a public key is neither. Putting it here is the whole point of a
    # declarative OS: key auth works on first boot, with no console dance and
    # nothing to recreate after a reinstall.
    #
    # (An earlier revision of this file left this commented out and pushed the
    # work into a manual `ssh-copy-id` step. That could never have worked —
    # sshd offers publickey only, so there was no way in to copy a key with.)
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINNWBbGHD+rSVTsJpL9vZYqKYqbIbbtYpSP99IL9ih9j fkberthold@gmail.com"
    ];

    # No password is set here, and that stays true: a password IS a credential,
    # and the Nix store is world-readable. `nixos-install` prompts for a root
    # password at the end of the install; set frank's from that console session
    # with `passwd frank` if you want sudo. SSH does not need it.
  };

  # `mutableUsers = true` is the NixOS default and we keep it, precisely so that
  # `passwd` works and no password has to live in this repo. The trade-off is
  # that passwords are machine state rather than declarative config — which for
  # a single-admin box is the right trade.

  # ---------------------------------------------------------------------------
  # Service account
  # ---------------------------------------------------------------------------
  # The single shared identity every container in the stack runs as. Contract §1
  # is explicit that there is no per-service variation.
  users.users.media = {
    isSystemUser = true;
    uid = 1500; # Contract §1 — compose PUID
    group = "media"; # GID 1500 — compose PGID
    description = "Shared service account for the palimpsest container stack";

    # No `shell` set on purpose: NixOS defaults system users to
    # ${pkgs.shadow}/bin/nologin, which is what we want. Stating it would just
    # be a second place to get it wrong.
    #
    # No home directory either — per-app state lives in
    # /opt/palimpsest-stack/<appname>/, owned by this user. See contract §3.
  };
}
