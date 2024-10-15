const std = @import("std");
const builtin = @import("builtin");

const qemu_args = .{
    "-cdrom", "sanity.iso",
};

pub fn build(b: *std.Build) void {
    const arch = b.option(std.Target.Cpu.Arch, "arch", "The target kernel architecture") orelse .x86_64;

    var code_model: std.builtin.CodeModel = .default;
    var linker_script_path: std.Build.LazyPath = undefined;
    var target_query: std.Target.Query = .{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
    };

    var xorriso_cmdline: []const []const u8 = undefined;
    var qemu_cmdline: []const []const u8 = undefined;

    switch (arch) {
        .x86_64 => {
            const Feature = std.Target.x86.Feature;

            target_query.cpu_features_add.addFeature(@intFromEnum(Feature.soft_float));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.mmx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse2));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx2));

            code_model = .kernel;
            linker_script_path = b.path("linker-x86_64.ld");
            xorriso_cmdline = &.{ "./scripts/xorriso-x86_64.sh" };
            qemu_cmdline = &(.{
                "qemu-system-x86_64",
                "-M", "q35",
                "-drive", "if=pflash,unit=0,format=raw,file=ovmf/ovmf-code-x86_64.fd,readonly=on",
            } ++ qemu_args);
        },
        .aarch64 => {
            const Feature = std.Target.aarch64.Feature;

            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.fp_armv8));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.crypto));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.neon));

            linker_script_path = b.path("linker-aarch64.ld");
            xorriso_cmdline = &.{ "./scripts/xorriso-aarch64.sh" };
            qemu_cmdline = &(.{
                "qemu-system-aarch64",
                "-M", "virt",
                "-cpu", "cortex-a72",
                "-device", "ramfb",
                "-device", "qemu-xhci",
                "-device", "usb-kbd",
                "-device", "usb-mouse",
                "-drive", "if=pflash,unit=0,format=raw,file=ovmf/ovmf-code-aarch64.fd,readonly=on",
            } ++ qemu_args);
        },
        .riscv64 => {
            const Feature = std.Target.riscv.Feature;

            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.d));

            linker_script_path = b.path("linker-riscv64.ld");
            xorriso_cmdline = &.{ "./scripts/xorriso-riscv64.sh" };
            qemu_cmdline = &(.{
                "qemu-system-riscv64",
                "-M", "virt",
                "-cpu", "rv64",
                "-device", "ramfb",
                "-device", "qemu-xhci",
                "-device", "usb-kbd",
                "-device", "usb-mouse",
                "-drive", "if=pflash,unit=0,format=raw,file=ovmf/ovmf-code-riscv64.fd,readonly=on",
            } ++ qemu_args);
        },
        else => std.debug.panic("Unsupported architecture: {s}", .{@tagName(arch)}),
    }

    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "sanity.elf",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = code_model,
    });

    kernel.setLinkerScript(linker_script_path);
    b.installArtifact(kernel);

    const kernel_step = b.step("kernel", "Build the kernel");
    kernel_step.dependOn(&kernel.step);

    const limine = addLimineSteps(b, b.getInstallStep(), xorriso_cmdline);

    addQemuSteps(b, limine, qemu_cmdline);
}

fn addLimineSteps(b: *std.Build, build_step: *std.Build.Step, xorriso_cmdline: []const []const u8) *std.Build.Step {
    const limine_clone = b.addSystemCommand(
        &.{"./scripts/limine_clone.sh"}
    );

    const limine_build = b.addExecutable(.{
        .name = "limine",
        .target = b.host,
        .optimize = .ReleaseSafe,
    });
    limine_build.linkLibC();
    limine_build.addCSourceFiles(
        .{ .files = &.{"limine/limine.c"} }
    );
    limine_build.step.dependOn(&limine_clone.step);

    const xorriso = b.addSystemCommand(xorriso_cmdline);
    xorriso.step.dependOn(build_step);
    xorriso.step.dependOn(&limine_build.step);

    const limine_run = b.addRunArtifact(limine_build);
    limine_run.addArgs(&.{"bios-install", "sanity.iso"});
    limine_run.step.dependOn(&limine_build.step);
    limine_run.step.dependOn(&xorriso.step);

    const limine_step = b.step("limine", "Setup limine");
    limine_step.dependOn(&limine_run.step);
    return &limine_run.step;
}

fn addQemuSteps(b: *std.Build, limine_step: *std.Build.Step, qemu_cmdline: []const []const u8) void {
    const ovmf = b.addSystemCommand(&.{ "./scripts/fetch_ovmf.sh" });
    const ovmf_step = b.step("ovmf", "Fetch OVMF");
    ovmf_step.dependOn(&ovmf.step);

    const qemu = b.addSystemCommand(qemu_cmdline);
    qemu.step.dependOn(limine_step);

    const qemu_step = b.step("qemu", "Run in QEMU");
    qemu_step.dependOn(&qemu.step);

    // Fetch ovmf if the ovmf directory does not exist
    _ = b.build_root.handle.openDir("ovmf", .{}) catch qemu_step.dependOn(&ovmf.step);
}
