{
  description = "A Nix flake continuously tracking fresh upstream Google Antigravity releases";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = { self, nixpkgs, flake-parts, ... }@inputs:
    let
      sources = builtins.fromJSON (builtins.readFile ./sources.json);
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      perSystem = { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            overlays = [ self.overlays.default ];
          };

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
            inherit (pkgs) antigravity-cli antigravity-hub antigravity-acp;
            inherit updater;
            default = pkgs.antigravity-cli;
          };

          apps = {
            default = {
              type = "app";
              program = "${pkgs.antigravity-cli}/bin/agy";
            };
            update = {
              type = "app";
              meta.description = "Update Antigravity versions from upstream manifests";
              program = "${updater}/bin/update";
            };
          };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.go
              pkgs.gopls
              updater
            ];
          };
        };

      flake = {
        overlays.default = final: prev:
          prev.lib.optionalAttrs (prev.stdenv.hostPlatform.system == "x86_64-linux") {
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

            antigravity-acp = prev.antigravity-acp.overrideAttrs (old: {
              version = sources.acp.version;
              src = final.fetchurl {
                url = "https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-${sources.acp.version}-linux-x86_64.zip";
                inherit (sources.acp) hash;
              };
              postInstall = (old.postInstall or "") + ''
                ln -s agy_acp_server.par $out/bin/agy-acp-server
                ln -s agy_acp_server.par $out/bin/antigravity-acp
              '';
            });
          };
      };
    };
}
