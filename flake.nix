{
  description = "A Nix flake continuously tracking fresh upstream Google Antigravity releases";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = { self, nixpkgs, flake-parts, ... }@inputs:
    let
      sources = builtins.fromJSON (builtins.readFile ./sources.json);

      mkAntigravityAcp = pkgs: versionInfo:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "antigravity-acp";
          version = versionInfo.version;
          src = pkgs.fetchurl {
            url = "https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-${versionInfo.version}-linux-x86_64.zip";
            inherit (versionInfo) hash;
          };
          nativeBuildInputs = [
            pkgs.unzip
            pkgs.autoPatchelfHook
          ];
          buildInputs = [
            pkgs.stdenv.cc.cc.lib
            pkgs.zlib
          ];
          sourceRoot = ".";
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp agy_acp_server.par localharness_external $out/bin/
            chmod +x $out/bin/agy_acp_server.par $out/bin/localharness_external
            ln -s agy_acp_server.par $out/bin/agy-acp-server
            ln -s agy_acp_server.par $out/bin/antigravity-acp
            runHook postInstall
          '';
          meta = with pkgs.lib; {
            description = "Google Antigravity Agent Client Protocol (ACP) server";
            homepage = "https://agentclientprotocol.com";
            license = licenses.unfree;
            platforms = [ "x86_64-linux" ];
            mainProgram = "agy_acp_server.par";
          };
        };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      perSystem = { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };

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

          antigravity-acp = mkAntigravityAcp pkgs sources.acp;

          updater = pkgs.buildGoModule {
            pname = "fresh-antigravity-updater";
            version = "0.1.0";
            src = ./.;
            vendorHash = null;
            env.CGO_ENABLED = "0";
            subPackages = [ "cmd/update" ];
          };
        in
        {
          packages = {
            inherit antigravity-cli antigravity-hub antigravity-acp updater;
            default = antigravity-cli;
          };

          apps.update = {
            type = "app";
            meta.description = "Update Antigravity versions from upstream manifests";
            program = "${updater}/bin/update";
          };
        };

      flake = {
        overlays.default = final: prev: {
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

          antigravity-acp = mkAntigravityAcp final sources.acp;
        };
      };
    };
}
