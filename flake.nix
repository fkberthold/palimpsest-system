{
  # ---------------------------------------------------------------------------
  # palimpsest — NixOS system layer
  #
  # This is the entry point. `nixos-rebuild` is pointed at this file and asks it
  # for the machine named `palimpsest`:
  #
  #     nixos-rebuild switch --flake /opt/palimpsest-system#palimpsest
  #
  # A flake has two halves: `inputs` (what we depend on, pinned to exact commits
  # in flake.lock) and `outputs` (what we produce — here, one machine).
  # ---------------------------------------------------------------------------
  description = "palimpsest — NixOS system layer for the household media server";

  inputs = {
    # Pinned to the nixos-26.05 STABLE release branch.
    #
    # Why 26.05 and not something newer or older:
    #   - It is the current stable release and still receives security updates.
    #     25.11 is at/past end of life, which is the wrong place to park a box
    #     that runs unattended.
    #   - It is NOT nixos-unstable. Unstable would mean the machine changes under
    #     us on every `nix flake update`, which is the opposite of what an
    #     appliance wants.
    #
    # This URL tracks the *branch*; flake.lock pins the exact commit. Nothing
    # moves until you deliberately run `nix flake update`.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # NOTE: there is deliberately no second `nixpkgs-unstable` input.
    # Prompt 1 asked me to check whether `claude-code` in stable was too old to
    # be useful and, if so, to pull just that package from unstable. I checked:
    # 26.05 ships claude-code 2.1.187, which is current. No unstable input is
    # needed, so we don't take on the complexity of one. See NOTES.md.
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
    in
    {
      # The machine. `nixos-rebuild --flake .#palimpsest` finds this attribute.
      nixosConfigurations.palimpsest = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./hosts/palimpsest/configuration.nix ];
      };

      # Makes `nix flake check` actually mean something.
      #
      # By default `nix flake check` would barely look at a flake whose only
      # output is a nixosConfiguration. Exposing the built system as a check
      # forces it to evaluate — and build — the whole machine.
      checks.${system}.toplevel =
        self.nixosConfigurations.palimpsest.config.system.build.toplevel;
    };
}
