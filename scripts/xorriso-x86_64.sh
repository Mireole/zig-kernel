#!/bin/bash

set -e

# Setup the iso root
rm -rf iso_root
mkdir -p iso_root/boot
cp -v zig-out/bin/sanity.elf iso_root/boot/
mkdir -p iso_root/boot/limine
cp -v limine.conf iso_root/boot/limine/
mkdir -p iso_root/EFI/BOOT

cp -v limine/limine-bios.sys limine/limine-bios-cd.bin limine/limine-uefi-cd.bin iso_root/boot/limine/
cp -v limine/BOOTX64.EFI iso_root/EFI/BOOT/
cp -v limine/BOOTIA32.EFI iso_root/EFI/BOOT/

# Call xorriso
xorriso -as mkisofs -b boot/limine/limine-bios-cd.bin \
		-no-emul-boot -boot-load-size 4 -boot-info-table \
		--efi-boot boot/limine/limine-uefi-cd.bin \
		-efi-boot-part --efi-boot-image --protective-msdos-label \
		iso_root -o sanity.iso

exit 0