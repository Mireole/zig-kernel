const std = @import("std");
const kernel = @import("kernel");
const builtin = @import("builtin");

const interrupts = kernel.interrupts;
const log = kernel.log;
const limine = kernel.limine;

const Dwarf = std.debug.Dwarf;

const native_arch = builtin.cpu.arch;
const native_endian = native_arch.endian();

// 8MiB should be plenty
var panic_allocator_buf: [8 * 1024 * 1024]u8 = undefined;
var panic_allocator_state = std.heap.FixedBufferAllocator.init(panic_allocator_buf[0..]);
const panic_allocator = panic_allocator_state.allocator();

// A frame pointer override for interrupts. Also triggers some logic to fixup stack traces from interrupts
// NOTE: this won't completely fixup stacktraces that contain nested interrupts
pub var interrupt_frame_pointer: ?usize = null;

pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (first_trace_addr) |addr| {
        log.writer.print("Kernel panic at 0x{x:0>16}\n{s}\n", .{ addr, msg }) catch {};
    } else {
        log.writer.print("Kernel panic at an unknown address!\n{s}\n", .{msg}) catch {};
    }
    // Just in case something goes wrong while printing the stack trace
    log.writer.flush() catch {};
    printStackTrace(first_trace_addr, interrupt_frame_pointer) catch {};
    log.writer.flush() catch {};

    interrupts.disable();
    kernel.hcf();
}

pub fn printStackTrace(first_trace_addr: ?usize, frame_pointer: ?usize) !void {
    const dwarf = getDwarfInfo();
    var it = std.debug.StackIterator.init(if (frame_pointer == null) first_trace_addr else null, frame_pointer);
    try log.writer.print("Stack trace:\n", .{});
    if (frame_pointer != null and first_trace_addr != null) {
        // The first line of the stack trace will be incorrect when an interrupt happened, fix it
        try printAddressInfo(dwarf, first_trace_addr.?);
        try log.writer.flush();
        _ = it.next();
    }
    while (it.next()) |address| {
        try printAddressInfo(dwarf, address);
        try log.writer.flush();
    }
}

pub fn printErrorTrace(stack_trace: *std.builtin.StackTrace) void {
    var frame_index: usize = 0;
    var frames_left: usize = @min(stack_trace.index, stack_trace.instruction_addresses.len);
    const dwarf = getDwarfInfo();

    log.writer.print("Stack trace:\n", .{}) catch {};
    while (frames_left != 0) : ({
        frames_left -= 1;
        frame_index = (frame_index + 1) % stack_trace.instruction_addresses.len;
    }) {
        const return_address = stack_trace.instruction_addresses[frame_index];
        printAddressInfo(dwarf, return_address) catch {};
    }

    if (stack_trace.index > stack_trace.instruction_addresses.len) {
        const dropped_frames = stack_trace.index - stack_trace.instruction_addresses.len;

        log.writer.print("({d} additional stack frames skipped...)\n", .{dropped_frames}) catch {};
    }
}

fn printAddressInfo(dwarf_opt: ?*Dwarf.ElfModule, address: usize) !void {
    if (dwarf_opt == null) {
        try log.writer.print("0x{x} in ???\n", .{ address });
        return;
    }
    const dwarf = dwarf_opt.?;
    const symbol = dwarf.getSymbolAtAddress(panic_allocator, address) catch {
        try log.writer.print("0x{x} in ???\n", .{ address });
        return;
    };
    if (symbol.source_location) |*sl| {
        defer panic_allocator.free(sl.file_name);
        try log.writer.print("{s}:{d}:{d}", .{ sl.file_name, sl.line, sl.column });
    } else {
        try log.writer.writeAll("???:?:?");
    }
    try log.writer.writeAll(" at ");
    try log.writer.print("0x{x} in {s} ({s})\n", .{ address, symbol.name, symbol.compile_unit_name });
}

fn getDwarfInfo() ?*Dwarf.ElfModule {
    if (limine.debug_file == null) return null;

    const module = panic_allocator.create(Dwarf.ElfModule) catch return null;
    const mapped_mem: []align(std.heap.page_size_min) const u8 = @alignCast(limine.debug_file.?);

    const hdr: *const std.elf.Ehdr = @ptrCast(&mapped_mem[0]);
    if (!std.mem.eql(u8, hdr.e_ident[0..4], std.elf.MAGIC)) return null;
    if (hdr.e_ident[std.elf.EI_VERSION] != 1) return null;

    const endian: std.builtin.Endian = switch (hdr.e_ident[std.elf.EI_DATA]) {
        std.elf.ELFDATA2LSB => .little,
        std.elf.ELFDATA2MSB => .big,
        else => return null,
    };
    if (endian != native_endian) return null;

    const shoff = hdr.e_shoff;
    const str_section_off = shoff + @as(u64, hdr.e_shentsize) * @as(u64, hdr.e_shstrndx);
    const str_shdr: *const std.elf.Shdr = @ptrCast(@alignCast(&mapped_mem[std.math.cast(usize, str_section_off) orelse return null]));
    const header_strings = mapped_mem[str_shdr.sh_offset..][0..str_shdr.sh_size];
    const shdrs = @as(
        [*]const std.elf.Shdr,
        @ptrCast(@alignCast(&mapped_mem[shoff])),
    )[0..hdr.e_shnum];

    var sections: Dwarf.SectionArray = Dwarf.null_section_array;

    errdefer for (sections) |opt_section| if (opt_section) |s| if (s.owned) panic_allocator.free(s.data);

    for (shdrs) |*shdr| {
        if (shdr.sh_type == std.elf.SHT_NULL or shdr.sh_type == std.elf.SHT_NOBITS) continue;
        const name = std.mem.sliceTo(header_strings[shdr.sh_name..], 0);

        var section_index: ?usize = null;
        inline for (@typeInfo(Dwarf.Section.Id).@"enum".fields, 0..) |sect, i| {
            if (std.mem.eql(u8, "." ++ sect.name, name)) section_index = i;
        }
        if (section_index == null) continue;
        if (sections[section_index.?] != null) continue;

        const section_bytes = Dwarf.chopSlice(mapped_mem, shdr.sh_offset, shdr.sh_size) catch return null;
        sections[section_index.?] = if ((shdr.sh_flags & std.elf.SHF_COMPRESSED) > 0) {
            // For now just ignore compressed sections
            // The code below was increasing the stack usage of this function by ~140KiB, which obviously didn't go well
            continue;
            // var section_stream = std.io.fixedBufferStream(section_bytes);
            // const section_reader = section_stream.reader();
            // const chdr = section_reader.readStruct(std.elf.Chdr) catch continue;
            // if (chdr.ch_type != .ZLIB) continue;

            // var zlib_stream = std.compress.zlib.decompressor(section_reader);

            // const decompressed_section = panic_allocator.alloc(u8, chdr.ch_size) catch return null;
            // errdefer panic_allocator.free(decompressed_section);

            // const read = zlib_stream.reader().readAll(decompressed_section) catch continue;
            // std.debug.assert(read == decompressed_section.len);

            // break :blk .{
            //     .data = decompressed_section,
            //     .virtual_address = shdr.sh_addr,
            //     .owned = true,
            // };
        } else .{
            .data = section_bytes,
            .virtual_address = shdr.sh_addr,
            .owned = false,
        };
    }

    var di: Dwarf = .{
        .endian = endian,
        .sections = sections,
        .is_macho = false,
    };

    Dwarf.open(&di, panic_allocator) catch return null;

    module.* = .{
        .base_address = 0,
        .dwarf = di,
        .mapped_memory = mapped_mem,
        .external_mapped_memory = null,
    };

    return module;
}