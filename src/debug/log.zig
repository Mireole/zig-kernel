const std = @import("std");
const root = @import("root");

const log = std.log;
const serial = root.serial;

fn writeFn(_: *const anyopaque, bytes: []const u8) !usize {
    return logFn(bytes);
}

pub fn logFn(format: []const u8) usize {
    if (@hasDecl(serial, "write_string")) {
        serial.write_string(format);
    }
    return format.len;
}

pub fn formattedLog(
    comptime message_level: log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    
    const writer = std.io.AnyWriter {
        .context = &{},
        .writeFn = writeFn,
    };

    if (@hasDecl(serial, "write_string")) {
        std.fmt.format(writer, level_txt ++ prefix2 ++ format ++ "\n", args) catch {};
    }
}