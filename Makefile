BUILD_DIR                  := build
# this is for downloaded content which need not be repeatedly done
DIST_DIR                   := dist

OVMF_DIR                   := $(DIST_DIR)/ovmf
OVMF_URL                   := https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd
OVMF_FILE                  := OVMF.fd

LIMINE_DIR                 := $(DIST_DIR)/limine

ISO_DIR                    := $(BUILD_DIR)/iso_root
ISO_FILE                   := $(BUILD_DIR)/os401b.iso

EFI_DIR                    := $(ISO_DIR)/EFI/BOOT
KERNEL_DIR                 := kernel
KERNEL_BIN                 := $(KERNEL_DIR)/zig-out/bin/kernel

# Zig compiler flags.
ZIG_FLAGS                  := -Doptimize=Debug

QEMU                       := qemu-system-x86_64
# use the `q35` machine model, emulating a more modern Intel chipset than the `pc` model, assign
# memory, instruct the VM to boot from the CD-ROM (drive `d`) first, ‘qemu64’ which provides a
# generic cpu with as many host-supported features and we and specify the CD-ROM ISO file
QEMU_COMMON_FLAGS          := -M q35 -m 128M -boot d -cdrom $(ISO_FILE) -cpu qemu64 -smp cores=2 -serial stdio

$(BUILD_DIR):
	@mkdir $(BUILD_DIR)

$(DIST_DIR):
	@mkdir $(DIST_DIR)

$(ISO_DIR): | $(BUILD_DIR)
	@mkdir $(ISO_DIR)

$(OVMF_DIR): | $(DIST_DIR)
	@mkdir $(OVMF_DIR)

$(EFI_DIR):  | $(ISO_DIR)
	@mkdir -p $(EFI_DIR)

# run using OVMF (UEFI)
.PHONY: run
run: $(OVMF_DIR)/$(OVMF_FILE) $(ISO_FILE)
	$(QEMU) -bios $(OVMF_DIR)/$(OVMF_FILE) -M smm=off $(QEMU_COMMON_FLAGS)

# run using legacy BIOS
.PHONY: run-bios
run-bios: $(ISO_FILE)
	$(QEMU) $(QEMU_COMMON_FLAGS)

# debug using QEMU and GDB
.PHONY: debug
debug: $(ISO_FILE)
	@echo "Starting QEMU..."
	$(QEMU) $(QEMU_COMMON_FLAGS) -d int -no-reboot -no-shutdown -S -s &
	@sleep 1
	@echo "Launching GDB..."
	cgdb -ex "target remote :1234" \
	    -ex "add-symbol-file kernel/zig-out/bin/kernel 0xffffffff80000000" \
	    kernel/zig-out/bin/kernel

$(OVMF_DIR)/$(OVMF_FILE): | $(OVMF_DIR)
	wget -O $(OVMF_DIR)/$(OVMF_FILE) $(OVMF_URL)

$(ISO_FILE): $(DIST_DIR)/limine kernel | $(ISO_DIR) $(EFI_DIR)
	cp -v boot/limine.conf $(ISO_DIR)
	cp -v $(KERNEL_BIN) $(ISO_DIR)

	cp -v $(LIMINE_DIR)/limine-bios.sys $(LIMINE_DIR)/limine-bios-cd.bin $(LIMINE_DIR)/limine-uefi-cd.bin $(ISO_DIR)

	cp -v $(LIMINE_DIR)/BOOTX64.EFI $(LIMINE_DIR)/BOOTIA32.EFI $(EFI_DIR)

	# Create the bootable ISO image.
	xorriso -as mkisofs -R -r -J -b limine-bios-cd.bin                \
			-no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
			-apm-block-size 2048 --efi-boot limine-uefi-cd.bin        \
			-efi-boot-part --efi-boot-image --protective-msdos-label  \
			$(ISO_DIR) -o $(ISO_FILE)

	$(LIMINE_DIR)/limine bios-install $(ISO_FILE)

	rm -rf $(ISO_DIR)


$(DIST_DIR)/limine: | $(DIST_DIR)
	git clone --depth 1 --branch=v8.x-binary https://github.com/limine-bootloader/limine.git $(LIMINE_DIR)
	$(MAKE) -C $(LIMINE_DIR)

.PHONY: kernel
kernel:
	cd kernel && zig build $(ZIG_FLAGS)

# clean up build artifacts
.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)

# clean up everything
.PHONY: distclean
distclean: clean
	rm -rf $(DIST_DIR)
	rm -rf $(KERNEL_DIR)/.zig-cache $(KERNEL_DIR)/zig-out
