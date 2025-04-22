const std = @import("std");
const root = @import("root");

const mem = root.mem;
const paging = root.paging;
const limine = root.limine;

const PhysAddr = root.types.PhysAddr;
const VirtAddr = root.types.VirtAddr;
const Error = mem.Error;
const Options = paging.Options;
const Spinlock = root.smp.Spinlock;

const assert = std.debug.assert;

pub const PageSize = enum {
    pub const default = .page_4kib;

    page_4kib,
    page_2mib,
    page_1gib,
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
    not_executable: bool,

    pub fn from(address: PhysAddr, options: Options) PageEntry {
        assert(address.v & ~address_mask == 0);
        const caching_bits: PATBits = @bitCast(options.caching);
        const entry = PageEntry {
            .writable = !options.read_only,
            .user = options.user,
            .write_through = caching_bits.pwt,
            .cache_disable = caching_bits.pcd,
            .pat = caching_bits.pat,
            .global = options.global,
            .address = 0,
            .protection_key = 0,
            .not_executable = !options.executable,
        };
        return @bitCast(@as(u64, @bitCast(entry)) | address.v);
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
    not_executable: bool,

    pub fn from(address: PhysAddr, options: Options) PageEntry {
        const address_mask = switch (options.page_size) {
            .page_2mib => address_mask_2mib,
            .page_1gib => address_mask_1gib,
            _ => unreachable,
        };
        assert(address.v & ~address_mask == 0);
        const caching_bits: PATBits = @bitCast(options.caching);
        const entry = PageEntry {
            .writable = !options.read_only,
            .user = options.user,
            .write_through = caching_bits.pwt,
            .cache_disable = caching_bits.pcd,
            .pat = caching_bits.pat,
            .global = options.global,
            .address = 0,
            .protection_key = 0,
            .not_executable = !options.executable,
        };
        return @bitCast(@as(u64, @bitCast(entry)) | address.v);
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
    not_executable: bool,

    pub fn from(address: PhysAddr, options: Options) PageEntry {
        assert(address.v & ~address_mask == 0);
        const entry = PageEntry {
            .writable = !options.read_only,
            .user = options.user,
            .address = 0,
            .protection_key = 0,
            .not_executable = !options.executable,
        };
        return @bitCast(@as(u64, @bitCast(entry)) | address.v);
    }

    pub fn getChild(directory: PageDirectory) PhysAddr {
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
    lam57_enable: bool = false,
    lam48_enable: bool = false,
    must_be_zero: bool = false,

    pub fn from(address: PhysAddr) CR3 {
        assert(address.v & ~address_mask == 0);
        const cr3 = CR3 {
            .address = 0,
        };
        return @bitCast(@as(u64, @bitCast(cr3)) | address.v);
    }

    pub inline fn get() CR3 {
        return asm volatile ("movq %%cr3, %[value]"
            : [value] "=&r" (-> CR3),
        );
    }

    pub inline fn set(cr3: CR3) void {
        asm volatile ("movq %[value], %%cr3"
            :
            : [value] "r" (cr3),
        );
    }
};

// TODO use mutexes
var map_lock: Spinlock = .{};

/// Creates paging structures to map the virtual address to the physical address.
/// If cr3_opt is null, the current cr3 is used as base.
pub fn map(phys: PhysAddr, virt: VirtAddr, cr3_opt: ?CR3, options: Options) Error!void {
    const cr3 = cr3_opt orelse CR3.get();
    if (options.early) return mapEarly(phys, virt, cr3, options);

    // TODO TLB shootdowns :^)
}

inline fn mapEarly(phys: PhysAddr, virt: VirtAddr, cr3: CR3, options: Options) Error!void {
    assert(options.early);

}