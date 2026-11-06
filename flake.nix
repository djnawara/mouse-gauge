{
  description = "MouseGauge: battery insights and controls for your mouse";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" ] (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.just
          ];

          shellHook = ''
            export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
            unset SDKROOT
            export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
            export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache"
            export SWIFTPM_BUILD_DIR="$PWD/.build"
          '';
        };
      }
    );
}
