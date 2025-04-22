pub const PhysAddr = packed struct(usize) {
    v: usize,

    pub inline fn from(value: anytype) PhysAddr {
        const T = @TypeOf(value);
        const addr = switch (@typeInfo(T)) {
            .comptime_int, .int, .comptime_float, .float => @as(usize, value),
            .pointer => |_| @intFromPtr(value),
            else => @compileError("Can't initialize a PhysAddr from a " ++ @typeName(T)),
        };

        return PhysAddr{
            .v = addr,
        };
    }

    pub inline fn to(addr: PhysAddr, T: type) T {
        switch (@typeInfo(T)) {
            .comptime_int, .int, .comptime_float, .float => return @as(T, addr.v),
            .pointer => |_| return @ptrFromInt(addr.v),
            else => @compileError("Can't convert a PhysAddr to a " ++ @typeName(T)),
        }
    }

    pub inline fn get(addr: PhysAddr, T: type) T {
        return @as(*T, @ptrFromInt(addr.v)).*;
    }
};

pub const VirtAddr = PhysAddr;