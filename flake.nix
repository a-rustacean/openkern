{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs = inputs: {
    devShells = builtins.mapAttrs (system: pkgs: {
      default = pkgs.mkShell {
        buildInputs = with pkgs; [
          qemu
          zig
          zls
        ];
      };
    }) inputs.nixpkgs.legacyPackages;
  };
}
