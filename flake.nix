{
  description = "Karuta development shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  # The Swift toolchain and the macOS SDK come from Apple's Command Line Tools (SwiftUI's macros need
  # SDK 26), and signing and notarization stay with Apple's tools, so this shell only adds the other
  # tools. The build itself is unchanged: make app / make test.
  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAll (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            pkgs.gh
            pkgs.jq
            pkgs.shellcheck
            # make icon (scripts/make-icns.sh): rsvg-convert renders the SVG, pngquant makes the PNGs smaller
            pkgs.librsvg
            pkgs.pngquant
          ];
          shellHook = ''
            # Swift is Apple's (/usr/bin/swift; this shell adds no compiler). Use the SDK 26 of the Command
            # Line Tools when there is no Xcode. Don't let a Nix SDK setting leak in.
            unset DEVELOPER_DIR
            if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
              echo "karuta: install the Command Line Tools first (xcode-select --install)" >&2
            elif [ "$(/usr/bin/xcode-select -p)" = /Library/Developer/CommandLineTools ]; then
              sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
              if [ -d "$sdk" ]; then
                export SDKROOT="$sdk"
              else
                echo "karuta: SDK 26 is missing from the Command Line Tools; SwiftUI's macros won't build" >&2
              fi
            fi
          '';
        };
      });
    };
}
