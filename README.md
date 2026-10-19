# Fresh Antigravity Nix Flake

A Nix flake tracking fresh upstream releases of Google Antigravity:
- **`antigravity-cli`**: Antigravity command line interface (`agy`)
- **`antigravity-hub`**: Antigravity desktop GUI
- **`antigravity-acp`**: Antigravity Agent Client Protocol server (`agy_acp_server.par`) for SolidCraft, Zed, JetBrains, etc.

## Why this flake?

Nixpkgs updates can lag behind upstream Google Antigravity binary releases by days or weeks. This flake:
- Automatically tracks upstream release manifests hourly.
- Downloads nothing if versions are already up-to-date (fast exit).
- Packages `antigravity-cli`, `antigravity-hub`, and `antigravity-acp` without obsolescence assert crashes when nixpkgs catches up.
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
    #   fresh-antigravity.packages.${system}.antigravity-acp
    # ];
    #
    # Or using the overlay:
    # nixpkgs.overlays = [ fresh-antigravity.overlays.default ];
  };
}
```

### Updating Locally

Run the updater app directly:
```bash
nix run .#update
```

## Automation

A scheduled GitHub Actions workflow checks for new upstream releases hourly. If an update is detected, it builds and verifies the packages (optionally pushing to Cachix) and commits the updated `sources.json`.
