# Fresh Antigravity Nix Flake

A Nix flake tracking fresh upstream releases of Google Antigravity ([Antigravity CLI](https://antigravity.google/) and Antigravity Hub).

## Why this flake?

Nixpkgs updates can lag behind upstream Google Antigravity binary releases by days or weeks. This flake:
- Automatically tracks upstream release manifests hourly.
- Downloads nothing if versions are already up-to-date (fast exit).
- Packages `antigravity-cli` and `antigravity-hub` without obsolescence assert crashes when nixpkgs catches up.
- Can build and push pre-patched derivations to Cachix so downloads and updates are instant.

## Usage

### Run directly
```bash
nix run github:goj/fresh-antigravity#antigravity-cli
```

### Add to NixOS / Home Manager
In your `flake.nix`:
```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    fresh-antigravity = {
      url = "github:goj/fresh-antigravity";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, fresh-antigravity, ... }: {
    # As packages:
    # home.packages = [
    #   fresh-antigravity.packages.${system}.antigravity-cli
    #   fresh-antigravity.packages.${system}.antigravity-hub
    # ];
    #
    # Or using the overlay:
    # nixpkgs.overlays = [ fresh-antigravity.overlays.default ];
  };
}
```

### Updating Locally

Run the smart update app directly:
```bash
nix run .#update
```
Or execute:
```bash
./update.sh
```

## Automation

A scheduled GitHub Actions workflow checks for new upstream releases hourly. If an update is detected, it builds and verifies the packages (optionally pushing to Cachix) and commits the updated `sources.json`.
