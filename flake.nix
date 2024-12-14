{
  description = "Development shell";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    formatter = pkgs.alejandra;
    devShells."${system}".default = pkgs.mkShell {
      packages = with pkgs; [
        gnumake
        libisoburn
        qemu
        zig
        zls
      ];
    };
  };
}
