# OS401b

This is a hobby OS made to learn about OS development as well as experiment with Zig.

The goal is to make a simple kernel targetting the x86_64 architecture with a focus on memory
safety.

![screenshot](screenshot.png)

## How to Run
You'll need the following packages installed (package names are according to
[nixpkgs](https://search.nixos.org/packages?channel=unstable)):
- [gnumake](https://www.gnu.org/software/make/)
- [libisoburn](http://libburnia-project.org/)
- [qemu](https://www.qemu.org/)
- [zig](https://ziglang.org/)
- [wget](https://www.gnu.org/software/wget/)
- (Optional) [zls](https://github.com/zigtools/zls) (This is just for LSP support in your editor)

If you're using Nix, there's a [flake.nix](flake.nix) setup with a development shell. You can just run `nix
develop` to enter the shell and all your dependencies will be available. See
[here](https://nixos.org/download/) for more info.

Once you have the dependencies in your `$PATH`, run the following:
```
make run
```

This should fetch, build the necessary files and run QEMU with the OS.

If you don't want to download and use the OVMF files for UEFI support, you can run:
```
make run-bios
```
This will run QEMU with the legacy BIOS.

## Roadmap
- [x] Limine bootloader setup
- [x] Framebuffer and fonts
- [x] IDT
- [x] Serial logging
- [x] GDT (remapping)
- [x] Physical Memory Allocator
- [x] Paging
- [x] ACPI Tables
- [x] APIC
- [x] Timer
- [x] Keyboard
- [ ] Virtual Memory Allocator
- [ ] Scheduler
- [ ] Userspace (system calls)
- [ ] File system (VFS)
- [ ] ELF loader
- [ ] Testing (memory safety)
