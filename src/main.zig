const std = @import("std");
const builtin = @import("builtin");

pub const limine = @import("limine.zig");
pub const types = @import("types.zig");
pub const acpi = @import("acpi/acpi.zig");
pub const zuacpi = @import("zuacpi");
pub const smp = @import("smp/smp.zig");
pub const log = @import("debug/log.zig");
pub const paging = @import("mem/paging.zig");
pub const mem = @import("mem/mem.zig");
pub const pmm = @import("mem/pmm.zig");
pub const vmm = @import("mem/vmm.zig");
pub const interrupts = @import("interrupt/interrupts.zig");

pub const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/arch.zig"),
    .aarch64 => @import("arch/aarch64/arch.zig"),
    .riscv64 => @import("arch/riscv64/arch.zig"),
    else => @compileError("Uknown arch"),
};
pub const serial = if(@hasDecl(arch, "serial")) arch.serial else struct {};

comptime {
    // Export uacpi related functions
    _ = zuacpi;
    _ = acpi;
}

pub const std_options = std.Options {
    .logFn = log.formattedLog,
};

pub const panic = std.debug.FullPanic(panicFn);

pub const zuacpi_options = zuacpi.Options {
    .allocator = acpi.allocator,
};

fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (first_trace_addr) |addr| {
        std.log.err("Kernel panic at {X:0>16}! {s}", .{ addr, msg });
    }
    else {
        std.log.err("Kernel panic at an unknown address! {s}", .{ msg });
    }
    interrupts.disable();
    hcf();
}

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

/// Called by Limine, uses the stack provided by Limine.
export fn _start() noreturn {
    if (!limine.limineBaseRevisionSupported()) {
        hcf();
    }

    if (@hasDecl(serial, "init")) {
        arch.serial.init();
        std.log.debug("Serial connection initialized", .{});
    }

    arch.init();

    limine.init();
    limine.drawLine(0);

    mem.init.init(types.VirtAddr.from(&init));
}

/// Called by mem.init.init once the VMBase has been set up.
/// It is called with a fresh kernel stack.
export fn init() noreturn {
    pmm.init();

    if (limine.rsdp) |_| {
        acpi.initialize(.{}) catch |err| std.log.err("Could not initialize ACPI: {}", .{err});
    }

    hcf();
}