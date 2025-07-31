{
  description = "Mirai-Gtk Development Environment & more";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            zig # 0.14.1
            pkg-config
            gtk2
            glib
            nodejs

            zls

            tree-sitter-grammars.tree-sitter-typescript
          ];
        };
      }
    );
}
