{
  description = "A Nix flake continuously tracking fresh upstream Google Antigravity releases";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = { self, nixpkgs, flake-parts, ... }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      perSystem = { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          sources = builtins.fromJSON (builtins.readFile ./sources.json);

          mkOverride =
            { basePkg
            , versionInfo
            , urlPattern
            , extraAttrs ? { }
            }:
            basePkg.overrideAttrs (old: {
              version = versionInfo.version;
              passthru = (old.passthru or { }) // {
                inherit (versionInfo) buildId;
              };
              src = pkgs.fetchurl {
                url = urlPattern versionInfo.version versionInfo.buildId;
                inherit (versionInfo) hash;
              };
            } // extraAttrs);

          antigravity-cli = mkOverride {
            basePkg = pkgs.antigravity-cli;
            versionInfo = sources.cli;
            urlPattern = v: b: "https://storage.googleapis.com/antigravity-public/antigravity-cli/${v}-${b}/linux-x64/cli_linux_x64.tar.gz";
            extraAttrs = {
              wholeVersion = "${sources.cli.version}-${sources.cli.buildId}";
            };
          };

          antigravity-hub = mkOverride {
            basePkg = pkgs.antigravity-hub;
            versionInfo = sources.hub;
            urlPattern = v: b: "https://storage.googleapis.com/antigravity-public/antigravity-hub/${v}-${b}/linux-x64/Antigravity.tar.gz";
          };
        in
        {
          packages = {
            inherit antigravity-cli antigravity-hub;
            default = antigravity-cli;
          };

          apps.update = {
            type = "app";
            meta.description = "Update Antigravity versions from upstream manifests";
            program = "${pkgs.writeShellApplication {
              name = "update";
              runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.nix pkgs.git ];
              text = builtins.readFile ./update.sh;
            }}/bin/update";
          };
        };

      flake = {
        overlays.default = final: prev:
          let
            sources = builtins.fromJSON (builtins.readFile ./sources.json);
          in
          {
            antigravity-cli = prev.antigravity-cli.overrideAttrs (old: {
              version = sources.cli.version;
              wholeVersion = "${sources.cli.version}-${sources.cli.buildId}";
              passthru = (old.passthru or { }) // {
                inherit (sources.cli) buildId;
              };
              src = final.fetchurl {
                url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${sources.cli.version}-${sources.cli.buildId}/linux-x64/cli_linux_x64.tar.gz";
                inherit (sources.cli) hash;
              };
            });

            antigravity-hub = prev.antigravity-hub.overrideAttrs (old: {
              version = sources.hub.version;
              passthru = (old.passthru or { }) // {
                inherit (sources.hub) buildId;
              };
              src = final.fetchurl {
                url = "https://storage.googleapis.com/antigravity-public/antigravity-hub/${sources.hub.version}-${sources.hub.buildId}/linux-x64/Antigravity.tar.gz";
                inherit (sources.hub) hash;
              };
            });
          };
      };
    };
}
