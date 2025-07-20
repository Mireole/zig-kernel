const std = @import("std");
const kernel = @import("kernel");

const log = std.log;
const serial = kernel.serial;

fn writeFn(_: *const anyopaque, bytes: []const u8) !usize {
    return logFn(bytes);
}

pub fn logFn(format: []const u8) usize {
    if (@hasDecl(serial, "writeString")) {
        serial.writeString(format);
    }
    return format.len;
}

pub fn formattedLog(
    comptime message_level: log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // TODO SMP: Thread safety ?
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    const writer = std.io.AnyWriter{
        .context = &{},
        .writeFn = writeFn,
    };
    writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch {};
}
