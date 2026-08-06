{
    description = "prewarm - keep the pages applications need resident";

    inputs = {
        nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
        flake-utils.url = "github:numtide/flake-utils";
    };

    outputs =
        {
            self,
            nixpkgs,
            flake-utils,
        }:
        flake-utils.lib.eachDefaultSystem (
            system:
            let
                pkgs = nixpkgs.legacyPackages.${system};
            in
            {
                packages.default = pkgs.stdenv.mkDerivation {
                    pname = "prewarm";
                    version = "0.1.0";
                    src = ./.;

                    nativeBuildInputs = [
                        pkgs.vala
                        pkgs.pkg-config
                    ];

                    buildInputs = [ pkgs.glib ];

                    buildPhase = ''
                        runHook preBuild
                        valac --pkg posix --pkg glib-2.0 -X -O2 -o prewarm src/prewarm.vala
                        runHook postBuild
                    '';

                    installPhase = ''
                        runHook preInstall
                        install -Dm755 prewarm $out/bin/prewarm
                        runHook postInstall
                    '';

                    meta = {
                        description = "Keep the pages applications need resident";
                        mainProgram = "prewarm";
                        platforms = pkgs.lib.platforms.linux;
                    };
                };

                apps.default = {
                    type = "app";
                    program = "${self.packages.${system}.default}/bin/prewarm";
                };

                devShells.default = pkgs.mkShell {
                    nativeBuildInputs = [
                        pkgs.vala
                        pkgs.pkg-config
                    ];
                    buildInputs = [ pkgs.glib ];
                };
            }
        )
        // {
            nixosModules.default = import ./module.nix self;
        };
}
