const std = @import("std");
const kernel = @import("kernel");

const log = std.log;
const serial = kernel.serial;
const framebuffer = kernel.framebuffer;

const Writer = std.Io.Writer;

var buffer: [1024]u8 = undefined;
pub var writer = Writer{
    .buffer = &buffer,
    .vtable = &.{
        .drain = &drain,
    }
};

fn drain(w: *Writer, data: []const []const u8, splat: usize) !usize {
    _ = logFn(w.buffer[0..w.end]);
    w.end = 0;
    var bytes: usize = 0;
    for (data[0..data.len - 1]) |buf| {
        bytes += buf.len;
        _ = logFn(buf);
    }
    const last = data[data.len - 1];
    for (0..splat) |_| {
        _ = logFn(last);
    }
    return bytes + last.len * splat;
}

pub fn logFn(format: []const u8) usize {
    if (@hasDecl(serial, "writeString")) {
        serial.writeString(format);
    }
    framebuffer.writeString(format);
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

    writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch {};
    writer.flush() catch {};
}
