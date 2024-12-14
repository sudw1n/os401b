# OS401b

This is a hobby OS made to learn about OS development as well as experiment with Zig.

The goal is to make a simple kernel targetting the x86_64 architecture with a focus on memory
safety.

## How to Run
You'll need the following packages installed (package names are according to
[nixpkgs](https://search.nixos.org/packages?channel=unstable)):
- [gnumake](https://www.gnu.org/software/make/)
- [libisoburn](http://libburnia-project.org/)
- [qemu](https://www.qemu.org/)
- [zig](https://ziglang.org/)
- (Optional) [zls](https://github.com/zigtools/zls) (This is just for LSP support in your editor)

If you're using Nix, there's a [flake.nix](flake.nix) setup with a development shell. You can just run `nix
develop` to enter the shell and all your dependencies will be available. See
[here](https://nixos.org/download/) for more info.

Once you have the dependencies in your `$PATH`, run the following:
```
make run
```

This should fetch, build the necessary files and run QEMU with the OS.
