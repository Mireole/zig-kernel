const std = @import("std");
const builtin = @import("builtin");

const Xorriso = @import("build/steps/Xorriso.zig");

const base_qemu_args = .{
    "-chardev",  "stdio,id=char0,logfile=logs/serial.log,signal=off",
    "-serial", "chardev:char0",
//    "-daemonize",
    "-smp", "2",
    "-D", "logs/qemu.log", // Log to logs/qemu.log
    "-m", "1G",
};

const qemu_debug_args = .{
    "-s", // Enable the gdb stub
    "-S", // Start on paused state
    "-no-reboot", "-no-shutdown" // Do not restart and hang after a triple fault
};

const Step = std.Build.Step;
const Dependency = std.Build.Dependency;

pub fn build(b: *std.Build) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("Memory leak");
    }

    const arch = b.option(std.Target.Cpu.Arch, "arch", "The target kernel architecture") orelse .x86_64;

    var code_model: std.builtin.CodeModel = .default;
    var linker_script_path: std.Build.LazyPath = undefined;
    var target_query: std.Target.Query = .{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
    };

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
            linker_script_path = b.path("build/linker-x86_64.ld");
            qemu_cmdline = &(.{
                "qemu-system-x86_64",
                "-cpu", "max",
                "-M", "q35",
                "-drive", "if=pflash,unit=0,format=raw,file=ovmf/ovmf-code-x86_64.fd,readonly=on",
                "-d", "int,page,cpu_reset,mmu", // Log useful info
            } ++ base_qemu_args);
        },
        .aarch64 => {
            const Feature = std.Target.aarch64.Feature;

            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.fp_armv8));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.crypto));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.neon));

            linker_script_path = b.path("build/linker-aarch64.ld");
            qemu_cmdline = &(.{
                "qemu-system-aarch64",
                "-M", "virt",
                "-cpu", "cortex-a72",
                "-device", "ramfb",
                "-device", "qemu-xhci",
                "-device", "usb-kbd",
                "-device", "usb-mouse",
                "-drive", "if=pflash,unit=0,format=raw,file=ovmf/ovmf-code-aarch64.fd,readonly=on",
            } ++ base_qemu_args);
        },
        .riscv64 => {
            const Feature = std.Target.riscv.Feature;

            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.d));

            linker_script_path = b.path("build/linker-riscv64.ld");
            qemu_cmdline = &(.{
                "qemu-system-riscv64",
                "-M", "virt",
                "-cpu", "rv64",
                "-device", "ramfb",
                "-device", "qemu-xhci",
                "-device", "usb-kbd",
                "-device", "usb-mouse",
                "-drive", "if=pflash,unit=0,format=raw,file=ovmf/ovmf-code-riscv64.fd,readonly=on",
            } ++ base_qemu_args);
        },
        else => std.debug.panic("Unsupported architecture: {s}", .{@tagName(arch)}),
    }

    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});

    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = code_model,
    });
    kernel_module.addImport("kernel", kernel_module);

    const test_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .code_model = code_model,
        .root_source_file = b.path("src/main.zig"),
    });
    test_module.addImport("kernel", test_module);

    const kernel = b.addExecutable(.{
        .name = "sanity.elf",
        .root_module = kernel_module,
        .use_llvm = true, // Needed for now as the self hosted backed crashes
                          // TODO remove this when the self hosted backend works well enough for Debug
    });

    const kernel_test = b.addTest(.{
        .name = "sanity.elf",
        .root_module = test_module,
        .use_llvm = true,
        .test_runner = .{ .path = b.path("build/runner.zig"), .mode = .simple },
        .emit_object = false,
    });

    const kernel_check = b.addExecutable(.{
        .name = "sanity.elf",
        .root_module = kernel_module,
    });

    kernel.setLinkerScript(linker_script_path);
    kernel_test.setLinkerScript(linker_script_path);
    kernel_check.setLinkerScript(linker_script_path);

    b.installArtifact(kernel);

    const kernel_step = b.step("kernel", "Build the kernel");
    kernel_step.dependOn(&kernel.step);

    const kernel_test_step = b.step("kernel-test", "Build the kernel with tests");
    kernel_test_step.dependOn(&kernel_test.step);

    const kernel_check_step = b.step("check", "Build the kernel without emitting binaries");
    kernel_check_step.dependOn(&kernel_check.step);

    // Limine
    var limine_dep = b.dependency("limine", .{
        .target = target,
        .optimize = optimize,
    });

    const translate_header = b.addTranslateC(.{
        .root_source_file = limine_dep.path("limine.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    translate_header.defineCMacro("LIMINE_API_REVISION", "2");

    const limine_module = translate_header.addModule("limine");
    kernel_module.addImport("limine", limine_module);
    test_module.addImport("limine", limine_module);

    // Zuacpi
    const zuacpi = b.dependency("zuacpi", .{
        .log_level = .info,
        .override_arch_helpers = false,
    });

    const zuacpi_module = zuacpi.module("zuacpi");
    kernel_module.addImport("zuacpi", zuacpi_module);
    test_module.addImport("zuacpi", zuacpi_module);

    const xorriso = Xorriso.create(b, arch, kernel, limine_dep);
    const xorriso_test = Xorriso.create(b, arch, kernel_test, limine_dep);

    const limine = addLimineSteps(b, limine_dep, xorriso);
    const limine_test = addLimineSteps(b, limine_dep, xorriso_test);

    const other_args: []const []const u8 = switch (optimize) {
        .Debug => &qemu_debug_args,
        else => &qemu_debug_args,
    };

    const qemu_args = try std.mem.concat(allocator, []const u8, &.{qemu_cmdline, other_args});
    defer allocator.free(qemu_args);

    addQemuSteps(b, limine, limine_test, xorriso, xorriso_test, qemu_args, kernel, kernel_test);
}

fn addLimineSteps(b: *std.Build, dep: *Dependency, xorriso_step: *Xorriso) *Step {
    const module = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const limine_build = b.addExecutable(.{
        .name = "limine",
        .root_module = module,
    });
    limine_build.linkLibC();
    limine_build.addCSourceFiles(.{ .files = &.{"limine.c"}, .root = dep.path("") });

    const limine_run = b.addRunArtifact(limine_build);
    limine_run.addArg("bios-install");
    limine_run.addFileArg(xorriso_step.output_path);
    const install = b.addInstallFile(xorriso_step.output_path, "sanity.iso");
    install.step.dependOn(&limine_run.step);
    b.getInstallStep().dependOn(&install.step);

    limine_run.step.dependOn(&limine_build.step);
    limine_run.step.dependOn(&xorriso_step.step);

    return &limine_run.step;
}

fn addQemuSteps(
    b: *std.Build,
    limine_step: *Step,
    limine_test_step: *Step,
    xorriso: *Xorriso,
    xorriso_test: *Xorriso,
    qemu_cmdline: []const []const u8,
    step: *Step.Compile,
    test_step: *Step.Compile,
) void {
    const ovmf = b.addSystemCommand(&.{ "./scripts/fetch_ovmf.sh" });
    const ovmf_step = b.step("ovmf", "Fetch OVMF");
    ovmf_step.dependOn(&ovmf.step);

    const qemu = b.addSystemCommand(qemu_cmdline);
    qemu.addArg("-cdrom");
    qemu.addFileArg(xorriso.output_path);
    qemu.step.dependOn(limine_step);

    const qemu_step = b.step("qemu", "Run in QEMU");
    qemu_step.dependOn(&qemu.step);

    const qemu_install_step = b.step("qemu-install", "Run in QEMU and output the ELF");
    qemu_install_step.dependOn(&qemu.step);
    qemu_install_step.dependOn(&b.addInstallArtifact(step, .{}).step);

    const qemu_test = b.addSystemCommand(qemu_cmdline);
    qemu_test.addArg("-cdrom");
    qemu_test.addFileArg(xorriso_test.output_path);
    qemu_test.step.dependOn(limine_test_step);

    const qemu_test_step = b.step("qemu-test", "Run tests in QEMU and output the ELF");
    qemu_test_step.dependOn(&qemu_test.step);
    qemu_test_step.dependOn(&b.addInstallArtifact(test_step, .{}).step);
}
