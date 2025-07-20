const std = @import("std");
const kernel = @import("kernel");

const cpuid = @import("cpuid.zig");

const mem = kernel.mem;
const paging = kernel.paging;
const limine = kernel.limine;
const arch = kernel.arch;

const PhysAddr = kernel.types.PhysAddr;
const VirtAddr = kernel.types.VirtAddr;
const Error = mem.Error;
const Options = paging.Options;
const Spinlock = kernel.smp.Spinlock;

const assert = std.debug.assert;

pub const levels = 4;
// Sizes of the areas mapped by each paging entry level
const mapped_areas: [levels]usize = .{
    0x1000, 0x200000, 0x40000000, 0x8000000000,
};

var zero_pages: [levels - 1]PhysAddr = undefined;

/// Physical page sizes
pub const PageSize = enum(usize) {
    page_4kib = 0x1000,
    page_2mib = 0x200000,
    page_1gib = 0x40000000,

    pub inline fn largest() PageSize {
        return if (cpuid.huge_pages) .page_1gib else .page_2mib;
    }

    pub inline fn default() PageSize {
        return .page_4kib;
    }

    pub inline fn get(size: PageSize) usize {
        return @intFromEnum(size);
    }
};

const PATBits = packed struct(u3) {
    pwt: bool,
    pcd: bool,
    pat: bool,
};

pub const Caching = enum(u3) {
    pub const default = .write_back;

    // Keeping the state limine sets the PAT to
    // https://github.com/limine-bootloader/limine/blob/v8.x/PROTOCOL.md#x86-64
    write_back,
    write_through,
    uncacheable_minus,
    uncacheable,
    write_protected,
    write_combining,
};

const PageEntry = packed struct(u64) {
    const address_mask = 0x000FFFFFFFFFF000;

    present: bool = true,
    writable: bool,
    user: bool,
    write_through: bool,
    cache_disable: bool,
    accessed: bool = false,
    dirty: bool = false,
    pat: bool,
    global: bool,
    ignored: u3 = 0,
    address: u40,
    ignored2: u7 = 0,
    protection_key: u4,
    not_executable: bool = false,

    pub fn from(address: PhysAddr, options: Options) PageEntry {
        assert(address.v & 0xFFF == 0);
        const caching_bits: PATBits = @bitCast(@intFromEnum(options.caching));
        const entry = PageEntry{
            .writable = !options.read_only,
            .user = options.user,
            .write_through = caching_bits.pwt,
            .cache_disable = caching_bits.pcd,
            .pat = caching_bits.pat,
            .global = options.global,
            .address = 0,
            .protection_key = 0,
        };
        return @bitCast(@as(u64, @bitCast(entry)) | (address.v & address_mask));
    }
};

const PageEntryHuge = packed struct(u64) {
    const address_mask_2mib = 0x000FFFFFFFE00000;
    const address_mask_1gib = 0x000FFFFFD0000000;

    present: bool = true,
    writable: bool,
    user: bool,
    write_through: bool,
    cache_disable: bool,
    accessed: bool = false,
    dirty: bool = false,
    page_size: bool = true,
    global: bool,
    ignored: u3 = 0,
    pat: bool,
    address: u39,
    ignored2: u7 = 0,
    protection_key: u4,
    not_executable: bool = false,

    pub fn from(address: PhysAddr, options: Options) PageEntryHuge {
        const address_mask: usize = switch (options.page_size) {
            .page_2mib => address_mask_2mib,
            .page_1gib => address_mask_1gib,
            else => unreachable,
        };
        assert(address.v & 0xFFF == 0);
        const caching_bits: PATBits = @bitCast(@intFromEnum(options.caching));
        const entry = PageEntryHuge{
            .writable = !options.read_only,
            .user = options.user,
            .write_through = caching_bits.pwt,
            .cache_disable = caching_bits.pcd,
            .pat = caching_bits.pat,
            .global = options.global,
            .address = 0,
            .protection_key = 0,
            //            .not_executable = !options.executable,
        };
        return @bitCast(@as(u64, @bitCast(entry)) | (address.v & address_mask));
    }
};

const PageDirectory = packed struct(u64) {
    const address_mask = 0x000FFFFFFFFFF000;

    present: bool = true,
    writable: bool,
    user: bool,
    write_through: bool = false, // Both WT and CD are set to false to select PAT 0 (WB),
    cache_disable: bool = false, // to make sure that paging structures are cached properly
    accessed: bool = false,
    ignored: bool = false,
    page_size: bool = false,
    must_be_zero: bool = false, // Ignored on PDPE and PDE
    ignored2: u3 = 0,
    address: u40,
    ignored3: u11 = 0,
    not_executable: bool = false, // Defaults to false because NXE might not be enabled

    pub fn from(address: PhysAddr, options: Options) PageDirectory {
        assert(address.v & 0xFFF == 0);
        const entry = PageDirectory{
            .writable = !options.read_only,
            .user = options.user,
            .address = 0,
            //            .not_executable = !options.executable,
        };
        return @bitCast(@as(u64, @bitCast(entry)) | (address.v & address_mask));
    }

    pub fn getTableAddr(directory: PageDirectory) PhysAddr {
        const addr = @as(usize, @bitCast(directory)) & address_mask;
        return PhysAddr.from(addr);
    }
};

const CR3 = packed struct(u64) {
    const address_mask = 0x000FFFFFFFFFF000;

    ignored: u3 = 0,
    write_through: bool = false,
    cache_disable: bool = false,
    ignored2: u7 = 0,
    address: u40,
    must_be_zero: u9 = 0,
    lam57_enable: bool = false,
    lam48_enable: bool = false,
    must_be_zero2: bool = false,

    pub fn from(address: PhysAddr) CR3 {
        assert(address.v & 0xFFF == 0);
        const cr3 = CR3{
            .address = 0,
        };
        return @bitCast(@as(u64, @bitCast(cr3)) | (address.v & address_mask));
    }

    pub fn setAddress(cr3: *CR3, address: PhysAddr) void {
        cr3.address = 0;
        cr3.* = @bitCast(@as(u64, @bitCast(cr3.*)) | (address.v & address_mask));
    }

    pub inline fn get() CR3 {
        return asm volatile (
            \\ movq %%cr3, %[value]
            : [value] "=&r" (-> CR3),
        );
    }

    pub inline fn set(cr3: CR3, new_stack: VirtAddr, next: VirtAddr) noreturn {
        // Set cr3 to the new value
        // rsp = new_stack
        // jump to next
        asm volatile (
            \\ movq %[value], %%cr3
            \\ movq %[stack], %%rsp
            \\ jmpq *%[next]
            :
            : [value] "r" (cr3),
              [stack] "r" (new_stack),
              [next] "r" (next),
            : .{ .cc = true }
        );
        unreachable;
    }

    pub fn getTableAddr(cr3: CR3) PhysAddr {
        const addr = @as(usize, @bitCast(cr3)) & address_mask;
        return PhysAddr.from(addr);
    }
};

pub const VMBase = struct {
    cr3: CR3,

    /// Returns the current VMBase
    pub fn current() VMBase {
        return VMBase{
            .cr3 = CR3.get(),
        };
    }

    /// Create a new VMBase with the same parameters but with a different address
    /// The page should be cleared before being provided
    pub fn copy(base: VMBase, page: PhysAddr) VMBase {
        var new = base;
        new.cr3.setAddress(page);
        return new;
    }

    pub inline fn enable(base: VMBase, new_stack: VirtAddr, next: VirtAddr) noreturn {
        base.cr3.set(new_stack, next);
    }
};

const LinearAddr = packed struct(u64) {
    offset: u12,
    table: u9,
    directory: u9,
    directory_pointer: u9,
    pml4: u9,
    canonical: u16,

    pub inline fn from(addr: VirtAddr) LinearAddr {
        return @bitCast(addr.v);
    }
};

// TODO SCHED: use mutexes ?
var map_lock: Spinlock = .{};

pub fn map(phys: PhysAddr, virt: VirtAddr, vm_opt: ?VMBase, options: Options) Error!void {
    const vm_base = vm_opt orelse VMBase.current();
    if (options.early) return mapEarly(phys, virt, vm_base, options);

    @panic("TODO");
    // TODO: implement this (don't forget page invalidation, only needed when changing page perms / underlying phys addr)
    // TODO SMP: TLB shootdowns :^)
}

// NOTE: most of the options, notably global, are ignored right now
pub fn mapZero(start: VirtAddr, end: VirtAddr, vm_opt: ?VMBase, options: Options) Error!void {
    assert(options.read_only);
    const vm_base = vm_opt orelse VMBase.current();
    if (options.early) return mapZeroEarly(start, end, vm_base, options);

    @panic("TODO");
}

// Early methods - only called before the first VMBase is used

inline fn getPtrEarly(T: type, table_addr: PhysAddr, index: u9) *T {
    const table = limine.get(table_addr).toSlice(T, PageSize.default().get());
    return &table[index];
}

fn getOrCreateEarly(table_addr: PhysAddr, index: u9, options: Options) PageDirectory {
    const entry = getPtrEarly(PageDirectory, table_addr, index);

    if (!entry.present) {
        const page = mem.init.page_list.getPage();
        // clear page
        const page_bytes = limine.get(page).toSlice(u8, PageSize.default().get());
        @memset(page_bytes, 0);

        entry.* = PageDirectory.from(page, options);
    }

    return entry.*;
}

fn mapEarly(phys: PhysAddr, virt: VirtAddr, vm_base: VMBase, options: Options) Error!void {
    const existingMapping: Error!void = if (options.allow_existing) {} else Error.MappingAlreadyExists;
    // Here, no need to care about locking or TLB as this should only be called before SMP to setup the first VMM
    assert(options.early);

    const cr3 = vm_base.cr3;
    const addr = LinearAddr.from(virt);

    const pml4_entry = getOrCreateEarly(cr3.getTableAddr(), addr.pml4, options);

    if (options.page_size == .page_1gib) {
        const dir_ptr_entry = getPtrEarly(PageEntryHuge, pml4_entry.getTableAddr(), addr.directory_pointer);
        if (dir_ptr_entry.present)
            return existingMapping;

        // Create the mapping
        dir_ptr_entry.* = PageEntryHuge.from(phys, options);
        return;
    }

    const dir_ptr_entry = getOrCreateEarly(pml4_entry.getTableAddr(), addr.directory_pointer, options);

    if (options.page_size == .page_2mib) {
        const directory_entry = getPtrEarly(PageEntryHuge, dir_ptr_entry.getTableAddr(), addr.directory);
        if (directory_entry.present)
            return existingMapping;

        // Create the mapping
        directory_entry.* = PageEntryHuge.from(phys, options);
        return;
    }

    const directory_entry = getOrCreateEarly(dir_ptr_entry.getTableAddr(), addr.directory, options);
    const table_entry = getPtrEarly(PageEntry, directory_entry.getTableAddr(), addr.table);
    if (table_entry.present)
        return existingMapping;

    table_entry.* = PageEntry.from(phys, options);
}

fn mapZeroEarly(start: VirtAddr, end: VirtAddr, vm_base: VMBase, options: Options) Error!void {
    var existingMapping: bool = false;
    const cr3 = vm_base.cr3;
    // Here, no need to care about locking or TLB as this should only be called before SMP to setup the first VMM
    assert(options.early);

    var current = start;
    while (current.v < end.v) {
        const addr = LinearAddr.from(current);
        const pml4_entry = getOrCreateEarly(cr3.getTableAddr(), addr.pml4, options);
        if (current.v & (mapped_areas[2] - 1) == 0 and current.v + mapped_areas[2] <= end.v) {
            const dir_ptr_entry = getPtrEarly(PageDirectory, pml4_entry.getTableAddr(), addr.directory_pointer);
            if (dir_ptr_entry.present) {
                existingMapping = true;
            } else {
                dir_ptr_entry.* = PageDirectory.from(zero_pages[2], options);
            }
            current = current.add(mapped_areas[2]);
            continue;
        }

        const dir_ptr_entry = getOrCreateEarly(pml4_entry.getTableAddr(), addr.directory_pointer, options);
        if (current.v & (mapped_areas[1] - 1) == 0 and current.v + mapped_areas[1] <= end.v) {
            const dir_entry = getPtrEarly(PageDirectory, dir_ptr_entry.getTableAddr(), addr.directory);
            if (dir_entry.present) {
                existingMapping = true;
            } else {
                dir_entry.* = PageDirectory.from(zero_pages[1], options);
            }
            current = current.add(mapped_areas[1]);
            continue;
        }

        const dir_entry = getOrCreateEarly(dir_ptr_entry.getTableAddr(), addr.directory, options);
        if (current.v & (mapped_areas[0] - 1) == 0 and current.v + mapped_areas[0] <= end.v) {
            const table_entry = getPtrEarly(PageEntry, dir_entry.getTableAddr(), addr.table);
            if (table_entry.present) {
                existingMapping = true;
            } else {
                table_entry.* = PageEntry.from(zero_pages[0], options);
            }
            current = current.add(mapped_areas[0]);
            continue;
        }
        unreachable; // Address not aligned
    }

    if (existingMapping and !options.allow_existing) return Error.MappingAlreadyExists;
}

pub fn initZeroPages() void {
    const options = Options{
        .executable = false,
        .global = false,
        .read_only = true,
        .user = true,
    };

    const page_list = &mem.init.page_list;

    const page_phys = page_list.getPage();
    const page = limine.get(page_phys);
    @memset(page.toSlice(u8, 4096), 0);
    zero_pages[0] = page_phys;

    const entry = PageEntry.from(page_phys, options);
    const page_dir_phys = page_list.getPage();
    const page_dir = limine.get(page_dir_phys);
    @memset(page_dir.toSlice(PageEntry, 512), entry);
    zero_pages[1] = page_dir_phys;

    const dir_entry = PageDirectory.from(page_dir_phys, options);
    const page_dir_ptr_phys = page_list.getPage();
    const page_dir_ptr = limine.get(page_dir_ptr_phys);
    @memset(page_dir_ptr.toSlice(PageDirectory, 512), dir_entry);
    zero_pages[2] = page_dir_ptr_phys;
}
