const std = @import("std");
const kernel = @import("kernel");

const types = kernel.types;
const VirtAddr = types.VirtAddr;

pub const Status = packed struct(u64) {
    interrupts_enabled: bool,
    _padding: u63 = 0,
};

const interrupt_flag_mask = 1 << 9;

const TableDescriptor = packed struct {
    limit: u16,
    offset: u64,
};

const GDTEntry = packed struct(u128) {
    limit2: u16 = 0xFFFF,
    base2: u24 = 0,
    access: packed struct(u8) {
        accessed: bool = false,
        read_write: bool = true,
        conforming: bool = false,
        executable: bool,
        segment_type: u1 = 1,
        ring: u2,
        present: bool = true,
    },
    limit1: u4 = 0xF,
    flags: packed struct(u4) {
        reserved: u1 = 0,
        long_code: bool,
        size: bool,
        granularity: bool = true,
    },
    base1: u40 = 0,
    reserved: u32 = 0,
};

const IDTEntry = packed struct(u128) {
    const GateType = enum(u4) {
        interrupt = 0xE,
        trap = 0xF,
    };

    offset1: u16,
    segment: u16,
    ist: u3,
    reserved: u5 = 0,
    gate_type: GateType,
    reserved2: u1 = 0,
    ring: u2,
    present: bool = true,
    offset2: u48,
    reserved3: u32 = 0,

    pub fn from(handler: VirtAddr, segment: u16, ist: u3, ring: u2) IDTEntry {
        const gate_type = .interrupt;
        return IDTEntry{
            .offset1 = @intCast(handler.v & 0xFFFF),
            .segment = segment,
            .ist = ist,
            .gate_type = gate_type,
            .ring = ring,
            .offset2 = @intCast(handler.v >> 16),
        };
    }

    pub fn setHandler(entry: *IDTEntry, handler: VirtAddr) void {
        entry.offset1 = @intCast(handler.v & 0xFFFF);
        entry.offset2 = @intCast(handler.v >> 16);
    }
};

const InterruptFrame = extern struct {
    ip: usize,
    cs: usize,
    flags: usize,
    sp: usize,
    ss: usize,
};

const null_descriptor: GDTEntry = @bitCast(@as(u128, 0));
const kernel_code = GDTEntry{
    .access = .{
        .executable = true,
        .ring = 0,
    },
    .flags = .{
        .long_code = true,
        .size = false,
    },
};
const kernel_data = GDTEntry{
    .access = .{
        .executable = false,
        .ring = 0,
    },
    .flags = .{
        .long_code = false,
        .size = true,
    },
};
const user_code = GDTEntry{
    .access = .{
        .executable = true,
        .ring = 3,
    },
    .flags = .{
        .long_code = true,
        .size = false,
    },
};
const user_data = GDTEntry{
    .access = .{
        .executable = false,
        .ring = 3,
    },
    .flags = .{
        .long_code = false,
        .size = true,
    },
};

var gdt align(0x10) = [_]GDTEntry {
    null_descriptor,
    kernel_code,
    kernel_data,
    user_code,
    user_data,
};

const empty_idt_entry: IDTEntry = @bitCast(@as(u128, 0));
const int_placeholder = VirtAddr.from(0x0);
const error_placeholder = VirtAddr.from(0xFFFFFFFFFFFFFFF);

var idt: [256]IDTEntry = .{
    IDTEntry.from(int_placeholder, 0x10, 0, 0), // Division by 0
        IDTEntry.from(int_placeholder, 0x10, 0, 0), // Debug
        IDTEntry.from(int_placeholder, 0x10, 0, 0), // NMI
        IDTEntry.from(int_placeholder, 0x10, 0, 0), // Breakpoint
        IDTEntry.from(int_placeholder, 0x10, 0, 0), // Overflow
        IDTEntry.from(int_placeholder, 0x10, 0, 0), // Bound range exceeded
        IDTEntry.from(int_placeholder, 0x10, 0, 0), // Invalid opcode
        IDTEntry.from(int_placeholder, 0x10, 0, 0), // Device not available
        IDTEntry.from(error_placeholder, 0x10, 0, 0), // Double fault
        IDTEntry.from(int_placeholder, 0x10, 0, 0), // Coprocessor overrun
        IDTEntry.from(error_placeholder, 0x10, 0, 0), // Invalid TSS
        IDTEntry.from(error_placeholder, 0x10, 0, 0), // Segment not present
        IDTEntry.from(error_placeholder, 0x10, 0, 0), // Stack segment fault
        IDTEntry.from(error_placeholder, 0x10, 0, 0), // General protection fault
        IDTEntry.from(error_placeholder, 0x10, 0, 0), // Page fault
        empty_idt_entry, // Reserved
        IDTEntry.from(int_placeholder, 0x10, 0, 0), // x87 FPE
        IDTEntry.from(error_placeholder, 0x10, 0, 0), // Alignment check
        IDTEntry.from(int_placeholder, 0x10, 0, 0), // Machine check
        IDTEntry.from(int_placeholder, 0x10, 0, 0), // SIMD FPE
        IDTEntry.from(int_placeholder, 0x10, 0, 0), // Virtualization exception
        IDTEntry.from(error_placeholder, 0x10, 0, 0), // Control protection exception
    } ++ (.{ empty_idt_entry } ** 10) ++ (.{ IDTEntry.from(int_placeholder, 0x10, 0, 0) } ** 224);

var gdtr = TableDescriptor{
    .offset = 0,
    .limit = gdt.len * @sizeOf(GDTEntry) - 1,
};

var idtr = TableDescriptor{
    .offset = 0,
    .limit = idt.len * @sizeOf(IDTEntry) - 1,
};

/// GDT and IDT initialisation
pub fn init() void {
    // We already have Limine's GDT, this function replaces it and initializes an IDT
    disable();
    setGdt();
    std.log.debug("GDT init... OK", .{});
    setIdt();
    std.log.debug("IDT init... OK", .{});
}

fn setGdt() void {
    gdtr.offset = @intFromPtr(&gdt);
    asm volatile ("callq *%[setGdt]" :: [setGdt] "r" (&_setGdt) : .{ .rax = true });
}

noinline fn _setGdt() callconv(.naked) void {
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

fn setIdt() void {
    std.mem.doNotOptimizeAway(&defaultInterruptHandler);
    std.mem.doNotOptimizeAway(&defaultErrorHandler);
    const int_handler = VirtAddr.from(&defaultInterruptHandler);
    const error_handler = VirtAddr.from(&defaultErrorHandler);
    for (0..idt.len) |i| {
        const entry = &idt[i];
        if (entry.offset1 > 0) {
            entry.setHandler(error_handler);
        }
        else {
            entry.setHandler(int_handler);
        }
    }
    idt[0xE].setHandler(VirtAddr.from(&pageFaultHandler));

    idtr.offset = @intFromPtr(&idt);
    asm volatile ("lidt %[idt]" :: [idt] "*p" (&idtr));
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

fn defaultInterruptHandler(frame: *InterruptFrame) callconv(.{ .x86_64_interrupt = .{}}) void {
    _ = frame;
}

fn defaultErrorHandler(frame: *InterruptFrame, error_code: usize) callconv(.{ .x86_64_interrupt = .{}}) void {
    std.debug.panic(
        \\ ERROR:
        \\  RIP=  0x{x:0>16}
        \\  CS=   0x{x:0>16}
        \\  FLAGS=0x{x:0>16}
        \\  SP=   0x{x:0>16}
        \\  SS=   0x{x:0>16}
        \\ error code: 0x{x:0>16}
        , .{
            frame.ip,
            frame.cs,
            frame.flags,
            frame.sp,
            frame.ss,
            error_code,
        }
    );
}

fn pageFaultHandler(frame: *InterruptFrame, error_code: usize) callconv(.{ .x86_64_interrupt = .{}}) void {
    const cr2 = asm volatile ("movq %%cr3, %[value]" : [value] "=&r" (-> usize));
    std.debug.panic(
        \\ PAGE FAULT:
        \\  RIP=  0x{x:0>16}
        \\  CS=   0x{x:0>16}
        \\  FLAGS=0x{x:0>16}
        \\  SP=   0x{x:0>16}
        \\  SS=   0x{x:0>16}
        \\ address: 0x{x:0>16}
        \\ error code: 0x{x:0>4}
        , .{
            frame.ip,
            frame.cs,
            frame.flags,
            frame.sp,
            frame.ss,
            cr2,
            error_code,
        }
    );
}