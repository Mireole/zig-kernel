const std = @import("std");
const fs = std.fs;

const Build = std.Build;
const Step = Build.Step;
const Arch = std.Target.Cpu.Arch;
const MakeOptions = Step.MakeOptions;
const Dependency = Build.Dependency;
const LazyPath = Build.LazyPath;

const Xorriso = @This();

step: Step,
output_path: LazyPath,

pub fn create(b: *Build, arch: Arch, objcopy: *Step.ObjCopy, limine: *Dependency) *Xorriso {
    var xorriso = b.allocator.create(Xorriso) catch @panic("OOM");

    // Setup the iso root
    const files = Step.WriteFile.create(b);
    files.step.dependOn(&objcopy.step);
    // kernel.iso
    _ = files.addCopyFile(objcopy.getOutput(), objcopy.basename);
    // kernel.iso.debug
    _ = files.addCopyFile(objcopy.getOutputSeparatedDebug().?, b.fmt("{s}.debug", .{objcopy.basename}));
    // Limine config
    _ = files.addCopyFile(b.path("build/limine.conf"), "limine.conf");

    // Limine
    _ = files.addCopyFile(limine.path("limine-uefi-cd.bin"), "boot/limine/limine-uefi-cd.bin");

    switch (arch) {
        .x86_64 => {
            _ = files.addCopyFile(limine.path("limine-bios.sys"), "boot/limine/limine-bios.sys");
            _ = files.addCopyFile(limine.path("limine-bios-cd.bin"), "boot/limine/limine-bios-cd.bin");
            _ = files.addCopyFile(limine.path("BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
            _ = files.addCopyFile(limine.path("BOOTIA32.EFI"), "EFI/BOOT/BOOTIA32.EFI");
        },
        .aarch64 => {
            _ = files.addCopyFile(limine.path("BOOTAA64.EFI"), "EFI/BOOT/BOOTAA64.EFI");
        },
        .riscv64 => {
            _ = files.addCopyFile(limine.path("BOOTRISCV64.EFI"), "EFI/BOOT/BOOTRISCV64.EFI");
        },
        else => unreachable, // Already handled in build.zig
    }

    const dir = files.getDirectory();

    // Run xorriso
    const xorriso_step = Step.Run.create(b, "xorriso");
    xorriso_step.addArg("xorriso");
    xorriso_step.addArgs(&.{"-as", "mkisofs"});

    if (arch == .x86_64) {
        xorriso_step.addArgs(&.{"-b", "boot/limine/limine-bios-cd.bin"});
        xorriso_step.addArg("-no-emul-boot");
        xorriso_step.addArgs(&.{"-boot-load-size", "4"});
        xorriso_step.addArg("-boot-info-table");
    }

    xorriso_step.addArgs(&.{"--efi-boot", "boot/limine/limine-uefi-cd.bin"});
    xorriso_step.addArg("-efi-boot-part");
    xorriso_step.addArg("--efi-boot-image");
    xorriso_step.addArg("--protective-msdos-label");
    xorriso_step.addDirectoryArg(dir);

    xorriso_step.addArg("-o");
    const iso_path = xorriso_step.addOutputFileArg("kernel.iso");

    xorriso.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = "Xorriso",
            .owner = b,
        }),
        .output_path = iso_path,
    };

    xorriso.step.dependOn(&xorriso_step.step);

    return xorriso;
}