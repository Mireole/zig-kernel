const std = @import("std");
const builtin = @import("builtin");

pub const limine = @import("limine.zig");
pub const types = @import("types.zig");
pub const acpi = @import("acpi/acpi.zig");
pub const smp = @import("smp/smp.zig");
pub const log = @import("debug/log.zig");
pub const paging = @import("mem/paging.zig");
pub const mem = @import("mem/mem.zig");
pub const pmm = @import("mem/pmm.zig");

pub const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/arch.zig"),
    .aarch64 => @import("arch/aarch64/arch.zig"),
    .riscv64 => @import("arch/riscv64/arch.zig"),
    else => @compileError("Uknown arch"),
};
pub const serial = if(@hasDecl(arch, "serial")) arch.serial else struct {};

comptime {
    _ = acpi;
}

pub const std_options = std.Options {
    .logFn = log.formattedLog,
};

pub fn hcf() noreturn {
    std.log.debug("Entering HCF", .{});
    // Loop forever (until interrupted)
    while (true) {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile ("hlt"),
            .aarch64 => asm volatile ("wfi"),
            .riscv64 => asm volatile ("wfi"),
            else => unreachable,
        }
    }
}

export fn _start() noreturn {
    // Limine already gives us a stack, so we can just call
    kmain();
}

fn kmain() noreturn {
    if (!limine.limineBaseRevisionSupported()) {
        hcf();
    }
    
    if (@hasDecl(serial, "init")) {
        arch.serial.init();
    }

    limine.init();
    limine.drawLine(0);

    pmm.earlyInit();

    if (limine.rsdp) |_| {
        acpi.initialize(0) catch |err| std.log.err("Could not initialize ACPI: {}", .{err});
    }

    hcf();
}