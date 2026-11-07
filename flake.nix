{
  description = "Brave browser, repackaged from Brave's signed stable .deb";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      overlays.default = final: prev: {
        brave = final.callPackage ./package.nix { };
      };

      packages.${system} = {
        brave = pkgs.callPackage ./package.nix { };
        default = self.packages.${system}.brave;
      };

      apps.${system}.update = {
        type = "app";
        program = pkgs.lib.getExe (
          pkgs.writeShellApplication {
            name = "brave-update";
            runtimeInputs = [
              pkgs.python3
              pkgs.sequoia-sqv
            ];
            text = ''exec python3 ${./update.py} "$@"'';
          }
        );
      };
    };
}
