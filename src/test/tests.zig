const std = @import("std");
const builtin = @import("builtin");

pub const mem = @import("mem.zig");

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const logger = std.log.scoped(.@"test");

pub fn runTests() void {
    const total = builtin.test_functions.len;
    var failed: usize = 0;
    var passed: usize = 0;
    logger.info("Running {} tests...", .{ total });
    for (builtin.test_functions, 0..) |t, i| {
        t.func() catch |err| {
            logger.err("[{}/{}] {s} failed: {}", .{ i + 1, total, t.name, err });
            failed += 1;
            continue;
        };
        logger.info("[{}/{}] {s} passed", .{ i + 1, total, t.name });
        passed += 1;
    }
    logger.info("Finished running {} tests ({} passed, {} failed)", .{ total, passed, failed });

}

// Functions copied from std.testing, as there is no way to overwrite std.testing's print function right now
fn print(comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    } else {
        logger.err(fmt, args);
    }
}

pub inline fn expectEqual(expected: anytype, actual: anytype) !void {
    const T = @TypeOf(expected, actual);
    return expectEqualInner(T, expected, actual);
}

fn expectEqualInner(comptime T: type, expected: T, actual: T) !void {
    switch (@typeInfo(@TypeOf(actual))) {
        .noreturn,
        .@"opaque",
        .frame,
        .@"anyframe",
        => @compileError("value of type " ++ @typeName(@TypeOf(actual)) ++ " encountered"),

        .undefined,
        .null,
        .void,
        => return,

        .type => {
            if (actual != expected) {
                print("expected type {s}, found type {s}\n", .{ @typeName(expected), @typeName(actual) });
                return error.TestExpectedEqual;
            }
        },

        .bool,
        .int,
        .float,
        .comptime_float,
        .comptime_int,
        .enum_literal,
        .@"enum",
        .@"fn",
        .error_set,
        => {
            if (actual != expected) {
                print("expected {any}, found {any}\n", .{ expected, actual });
                return error.TestExpectedEqual;
            }
        },

        .pointer => |pointer| {
            switch (pointer.size) {
                .one, .many, .c => {
                    if (actual != expected) {
                        print("expected {*}, found {*}\n", .{ expected, actual });
                        return error.TestExpectedEqual;
                    }
                },
                .slice => {
                    if (actual.ptr != expected.ptr) {
                        print("expected slice ptr {*}, found {*}\n", .{ expected.ptr, actual.ptr });
                        return error.TestExpectedEqual;
                    }
                    if (actual.len != expected.len) {
                        print("expected slice len {}, found {}\n", .{ expected.len, actual.len });
                        return error.TestExpectedEqual;
                    }
                },
            }
        },

        .array => |array| try expectEqualSlices(array.child, &expected, &actual),

        .vector => |info| {
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                if (!std.meta.eql(expected[i], actual[i])) {
                    print("index {d} incorrect. expected {any}, found {any}\n", .{
                        i, expected[i], actual[i],
                    });
                    return error.TestExpectedEqual;
                }
            }
        },

        .@"struct" => |structType| {
            inline for (structType.fields) |field| {
                try expectEqual(@field(expected, field.name), @field(actual, field.name));
            }
        },

        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                const first_size = @bitSizeOf(union_info.fields[0].type);
                inline for (union_info.fields) |field| {
                    if (@bitSizeOf(field.type) != first_size) {
                        @compileError("Unable to compare untagged unions with varying field sizes for type " ++ @typeName(@TypeOf(actual)));
                    }
                }

                const BackingInt = std.meta.Int(.unsigned, @bitSizeOf(T));
                return expectEqual(
                    @as(BackingInt, @bitCast(expected)),
                    @as(BackingInt, @bitCast(actual)),
                );
            }

            const Tag = std.meta.Tag(@TypeOf(expected));

            const expectedTag = @as(Tag, expected);
            const actualTag = @as(Tag, actual);

            try expectEqual(expectedTag, actualTag);

            // we only reach this switch if the tags are equal
            switch (expected) {
                inline else => |val, tag| try expectEqual(val, @field(actual, @tagName(tag))),
            }
        },

        .optional => {
            if (expected) |expected_payload| {
                if (actual) |actual_payload| {
                    try expectEqual(expected_payload, actual_payload);
                } else {
                    print("expected {any}, found null\n", .{expected_payload});
                    return error.TestExpectedEqual;
                }
            } else {
                if (actual) |actual_payload| {
                    print("expected null, found {any}\n", .{actual_payload});
                    return error.TestExpectedEqual;
                }
            }
        },

        .error_union => {
            if (expected) |expected_payload| {
                if (actual) |actual_payload| {
                    try expectEqual(expected_payload, actual_payload);
                } else |actual_err| {
                    print("expected {any}, found {}\n", .{ expected_payload, actual_err });
                    return error.TestExpectedEqual;
                }
            } else |expected_err| {
                if (actual) |actual_payload| {
                    print("expected {}, found {any}\n", .{ expected_err, actual_payload });
                    return error.TestExpectedEqual;
                } else |actual_err| {
                    try expectEqual(expected_err, actual_err);
                }
            }
        },
    }
}

pub fn expectEqualSlices(comptime T: type, expected: []const T, actual: []const T) !void {
    const diff_index: usize = diff_index: {
        const shortest = @min(expected.len, actual.len);
        var index: usize = 0;
        while (index < shortest) : (index += 1) {
            if (!std.meta.eql(actual[index], expected[index])) break :diff_index index;
        }
        break :diff_index if (expected.len == actual.len) return else shortest;
    };
    failEqualSlices(T, expected, actual, diff_index) catch {};
    return error.TestExpectedEqual;
}

fn failEqualSlices(
    comptime T: type,
    expected: []const T,
    actual: []const T,
    diff_index: usize,
) !void {
    print("slices differ. first difference occurs at index {d} (0x{X})", .{ diff_index, diff_index });

    // TODO: Should this be configurable by the caller?
    const max_lines: usize = 16;
    const max_window_size: usize = if (T == u8) max_lines * 16 else max_lines;

    // Print a maximum of max_window_size items of each input, starting just before the
    // first difference to give a bit of context.
    var window_start: usize = 0;
    if (@max(actual.len, expected.len) > max_window_size) {
        const alignment = if (T == u8) 16 else 2;
        window_start = std.mem.alignBackward(usize, diff_index - @min(diff_index, alignment), alignment);
    }
    const expected_window = expected[window_start..@min(expected.len, window_start + max_window_size)];
    const expected_truncated = window_start + expected_window.len < expected.len;
    const actual_window = actual[window_start..@min(actual.len, window_start + max_window_size)];
    const actual_truncated = window_start + actual_window.len < actual.len;

    var differ = SliceDiffer(T){
        .start_index = window_start,
        .expected = expected_window,
        .actual = actual_window,
    };

    // Print indexes as hex for slices of u8 since it's more likely to be binary data where
    // that is usually useful.
    const index_fmt = if (T == u8) "0x{X}" else "{}";

    print("\n============ expected this output: =============  len: {} (0x{X})\n", .{ expected.len, expected.len });
    if (window_start > 0) {
        if (T == u8) {
            print("... truncated, start index: " ++ index_fmt ++ " ...", .{window_start});
        } else {
            print("... truncated ...", .{});
        }
    }
    differ.write() catch {};
    if (expected_truncated) {
        const end_offset = window_start + expected_window.len;
        const num_missing_items = expected.len - (window_start + expected_window.len);
        if (T == u8) {
            print("... truncated, indexes [" ++ index_fmt ++ "..] not shown, remaining bytes: " ++ index_fmt ++ " ...", .{ end_offset, num_missing_items });
        } else {
            print("... truncated, remaining items: " ++ index_fmt ++ " ...", .{num_missing_items});
        }
    }

    // now reverse expected/actual and print again
    differ.expected = actual_window;
    differ.actual = expected_window;
    print("\n============= instead found this: ==============  len: {} (0x{X})\n", .{ actual.len, actual.len });
    if (window_start > 0) {
        if (T == u8) {
            print("... truncated, start index: " ++ index_fmt ++ " ...", .{window_start});
        } else {
            print("... truncated ...", .{});
        }
    }
    differ.write() catch {};
    if (actual_truncated) {
        const end_offset = window_start + actual_window.len;
        const num_missing_items = actual.len - (window_start + actual_window.len);
        if (T == u8) {
            print("... truncated, indexes [" ++ index_fmt ++ "..] not shown, remaining bytes: " ++ index_fmt ++ " ...", .{ end_offset, num_missing_items });
        } else {
            print("... truncated, remaining items: " ++ index_fmt ++ " ...", .{num_missing_items});
        }
    }
    print("\n================================================\n", .{});

    return error.TestExpectedEqual;
}

fn SliceDiffer(comptime T: type) type {
    return struct {
        start_index: usize,
        expected: []const T,
        actual: []const T,

        const Self = @This();

        pub fn write(self: Self) !void {
            for (self.expected, 0..) |value, i| {
                const full_index = self.start_index + i;
                if (@typeInfo(T) == .pointer) {
                    print("[{}]{*}: {any}", .{ full_index, value, value });
                } else {
                    print("[{}]: {any}", .{ full_index, value });
                }
            }
        }
    };
}