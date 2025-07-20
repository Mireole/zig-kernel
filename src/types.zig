const kernel = @import("kernel");
const std = @import("std");

const paging = kernel.paging;
const vmm = kernel.vmm;

const Page = paging.Page;
const PageSize = paging.PageSize;

const assert = std.debug.assert;

pub const PhysAddr = packed struct(usize) {
    v: usize,

    pub inline fn from(value: anytype) PhysAddr {
        const T = @TypeOf(value);
        const addr = switch (@typeInfo(T)) {
            .comptime_int, .int, .comptime_float, .float => @as(usize, value),
            // .pointer => |_| @intFromPtr(value),
            else => @compileError("Can't initialize a PhysAddr from a " ++ @typeName(T)),
        };

        return PhysAddr{
            .v = addr,
        };
    }

    pub inline fn to(addr: PhysAddr, T: type) T {
        switch (@typeInfo(T)) {
            .comptime_int, .int, .comptime_float, .float => return @as(T, addr.v),
            // .pointer => |_| return @ptrFromInt(addr.v),
            else => @compileError("Can't convert a PhysAddr to a " ++ @typeName(T)),
        }
    }

    pub inline fn add(addr: PhysAddr, n: usize) PhysAddr {
        return PhysAddr.from(addr.v + n);
    }

    pub inline fn sub(addr: PhysAddr, n: usize) PhysAddr {
        return PhysAddr.from(addr.v - n);
    }

    pub inline fn page(addr: PhysAddr) *Page {
        const page_index = addr.v / PageSize.default().get();
        const virt_map = vmm.virt_map_start + page_index * @sizeOf(Page);

        return @ptrFromInt(virt_map);
    }

    pub inline fn hhdm(addr: PhysAddr) VirtAddr {
        return vmm.get(addr);
    }
};

pub const VirtAddr =  packed struct(usize) {
    v: usize,

    pub inline fn from(value: anytype) VirtAddr {
        const T = @TypeOf(value);
        const addr = switch (@typeInfo(T)) {
            .comptime_int, .int, .comptime_float, .float => @as(usize, value),
            .pointer => |_| @intFromPtr(value),
            else => @compileError("Can't initialize a VirtAddr from a " ++ @typeName(T)),
        };

        return VirtAddr{
            .v = addr,
        };
    }

    pub inline fn to(addr: VirtAddr, T: type) T {
        switch (@typeInfo(T)) {
            .comptime_int, .int, .comptime_float, .float => return @as(T, addr.v),
            .pointer => |_| return @ptrFromInt(addr.v),
            else => @compileError("Can't convert a VirtAddr to a " ++ @typeName(T)),
        }
    }

    pub inline fn toSlice(addr: VirtAddr, T: type, size: usize) []T {
        const ptr = addr.to([*]T);
        return ptr[0..size];
    }

    pub inline fn get(addr: VirtAddr, T: type) T {
        return @as(*T, @ptrFromInt(addr.v)).*;
    }

    pub inline fn add(addr: VirtAddr, n: usize) VirtAddr {
        return VirtAddr.from(addr.v + n);
    }

    pub inline fn sub(addr: VirtAddr, n: usize) VirtAddr {
        return VirtAddr.from(addr.v - n);
    }

    /// Align up the virtual address to a specific alignment (must be a power of 2)
    pub inline fn alignUp2(addr: VirtAddr, alignment: usize) VirtAddr {
        return VirtAddr.from((addr.v + alignment - 1) & ~(alignment - 1));
    }

    /// Align up the virtual down to a specific alignment (must be a power of 2)
    pub inline fn alignDown2(addr: VirtAddr, alignment: usize) VirtAddr {
        return VirtAddr.from(addr.v & ~(alignment - 1));
    }

    /// Returns a pointer to the corresponding page within the HHDM
    /// Note: this function assumes that the address is in the HHDM
    pub inline fn page(addr: VirtAddr) *Page {
        assert(addr.v >= vmm.hhdm_start and addr.v < vmm.hhdm_start + vmm.hhdm_size);

        return PhysAddr.from(addr.v - vmm.hhdm_start).page();
    }
};