const std = @import("std");
const kernel = @import("kernel");

const types = kernel.types;
const VirtAddr = types.VirtAddr;

pub const Status = packed struct(u64) {
    interrupts_enabled: bool,
    _padding: u63 = 0,
};

const interrupt_flag_mask = 1 << 9;

const GDTR = packed struct {
    limit: u16,
    offset: u64,
};

const GDTEntry = packed struct(u128) {
    limit2: u16 = 0xFFFF,
    base2: u24 = 0,
    access: packed struct(u8) {
        accessed: bool = false,
        read_write: bool,
        conforming: bool,
        executable: bool,
        segment_type: u1,
        ring: u2,
        present: bool = true,
    },
    limit1: u4 = 0xF,
    flags: packed struct(u4) {
        reserved: u1 = 0,
        long_code: bool,
        size: bool,
        granularity: bool,
    },
    base1: u40 = 0,
    reserved: u32 = 0,
};

const null_descriptor: GDTEntry = @bitCast(@as(u128, 0));
const kernel_code = GDTEntry{
    .access = .{
        .read_write = true,
        .conforming = false,
        .executable = true,
        .segment_type = 1,
        .ring = 0,
    },
    .flags = .{
        .long_code = true,
        .size = false,
        .granularity = true,
    },
};
const kernel_data = GDTEntry{
    .access = .{
        .read_write = true,
        .conforming = false,
        .executable = false,
        .segment_type = 1,
        .ring = 0,
    },
    .flags = .{
        .long_code = false,
        .size = true,
        .granularity = true,
    },
};
const user_code = GDTEntry{
    .access = .{
        .read_write = true,
        .conforming = false,
        .executable = true,
        .segment_type = 1,
        .ring = 3,
    },
    .flags = .{
        .long_code = true,
        .size = false,
        .granularity = true,
    },
};
const user_data = GDTEntry{
    .access = .{
        .read_write = true,
        .conforming = false,
        .executable = false,
        .segment_type = 1,
        .ring = 3,
    },
    .flags = .{
        .long_code = false,
        .size = true,
        .granularity = true,
    },
};

var gdt align(0x10) = [_]GDTEntry {
    null_descriptor,
    kernel_code,
    kernel_data,
    user_code,
    user_data,
};

var gdtr = GDTR{
    .offset = 0,
    .limit = gdt.len * @sizeOf(GDTEntry) - 1,
};

/// GDT and IDT initialisation
pub fn init() void {
    // We already have Limine's GDT, this function replaces it and initializes an IDT
    disable();
    gdtr.offset = @intFromPtr(&gdt);
    asm volatile ("callq *%[setGdt]" :: [setGdt] "r" (&setGdt) : .{ .rax = true });
    std.log.debug("GDT init... OK", .{});
}

noinline fn setGdt() callconv(.naked) void {
    const gdtr_ptr = &gdtr;

    asm volatile (
        \\ lgdt %[gdt]
        // Flush the segment registers
        \\ movq $0x20, %%rax
        \\ movq %%rax, %%ds
        \\ movq %%rax, %%es
        \\ movq %%rax, %%fs
        \\ movq %%rax, %%gs
        \\ movq %%rax, %%ss
        // Load the code segment selector
        \\ popq %%rax
        \\ pushq $0x10
        \\ pushq %%rax
        \\ lretq
        :
        : [gdt] "*p" (gdtr_ptr),
        : .{ .rax = true }
    );
}

/// Disable interrupts
pub fn disable() void {
    asm volatile ("cli");
}

/// Disable interrupts and return the previous state
pub fn save() Status {
    const flags = asm volatile ("pushf ; pop %[value]"
        : [value] "=r" (-> u64),
    );
    const interrupt_enable = flags & interrupt_flag_mask > 0;
    if (interrupt_enable) disable();

    return Status{
        .interrupts_enabled = interrupt_enable,
    };
}

pub fn enable() void {
    asm volatile ("sti");
}

/// Restore interrupts from the given state
pub fn restore(status: Status) void {
    if (status.interrupts_enabled) enable();
}
