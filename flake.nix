{
  description = "CLI tool for querying mmCIF PDBx dictionary definitions";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "mmcif-dict";
          version = "0.1.0";

          src = ./.;

          nativeBuildInputs = [ pkgs.zig ];

          dontConfigure = true;
          dontInstall = true;

          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            zig build -Doptimize=ReleaseFast --prefix $out
          '';

          meta = with pkgs.lib; {
            description = "CLI tool for querying mmCIF PDBx dictionary definitions";
            homepage = "https://github.com/N283T/mmcif-dict-cli";
            license = licenses.mit;
            mainProgram = "mmcif-dict";
          };
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            zig
          ];
        };
      }
    );
}
