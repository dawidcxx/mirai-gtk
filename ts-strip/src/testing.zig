const std = @import("std");

const Testing = @This();

allocator: std.mem.Allocator,
detect_leaks: bool,
suite_name: [:0]const u8,

const DefaultSuiteName = "ANONYMOUS";

pub fn run(testBody: fn (ctx: *Testing) anyerror!void) anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var test_context: Testing = .{ .allocator = allocator, .detect_leaks = true, .suite_name = DefaultSuiteName[0..] };

    std.testing.log_level = .info;

    testBody(&test_context) catch |e| {
        std.log.info("SUITE '{s}' FAIL ({s})", .{ test_context.suite_name, @errorName(e) });
        return e;
    };

    if (std.mem.eql(u8, test_context.suite_name, DefaultSuiteName[0..])) {
        std.log.err("FAIL: test suite must call Testing#register(@src())", .{});
        return error.TestUnexpectedResult;
    }

    if (test_context.detect_leaks) {
        if (gpa.detectLeaks()) {
            std.log.err("Memory leaks have been detected", .{});
            return error.TestUnexpectedResult;
        } else {
            std.log.debug("No memory leaks detected", .{});
        }
    }

    std.log.info("SUITE '{s}' SUCCESS", .{test_context.suite_name});
}

pub fn register(t: *Testing, comptime src: std.builtin.SourceLocation) void {
    t.suite_name = src.fn_name;
    std.log.info("SUITE '{s}' START", .{src.fn_name});
}

pub fn setLogLevel(t: Testing, level: std.log.Level) void {
    _ = t;
    std.testing.log_level = level;
}

pub fn strEq(t: Testing, msg: []const u8, a: []const u8, b: []const u8) anyerror!void {
    _ = t;
    std.testing.expectEqualStrings(b, a) catch |e| {
        logTestFail(msg);
        return e;
    };
    logTestPass(msg);
}

pub fn expectEqual(t: Testing, msg: []const u8, a: anytype, b: anytype) anyerror!void {
    _ = t;
    std.testing.expectEqual(a, b) catch |e| {
        logTestFail(msg);
        return e;
    };
    logTestPass(msg);
}

pub fn sliceEq(t: Testing, msg: []const u8, slice1: anytype, slice2: @TypeOf(slice1)) anyerror!void {
    _ = t;
    std.testing.expectEqualSlices(std.meta.Elem(@TypeOf(slice1)), slice1, slice2) catch |e| {
        logTestFail(msg);
        return e;
    };
    logTestPass(msg);
}

fn logTestPass(msg: []const u8) void {
    const target_width = 65;
    if (msg.len < target_width) {
        const padding = target_width - msg.len;
        std.log.info("TEST '{s}' {s:.<[2]} PASS", .{ msg, "", padding });
    } else {
        std.log.info("TEST '{s}' ... PASS", .{msg});
    }
}

fn logTestFail(msg: []const u8) void {
    const target_width = 65;
    if (msg.len < target_width) {
        const padding = target_width - msg.len;
        std.log.info("TEST '{s}' {s:.<[2]} FAIL", .{ msg, "", padding });
    } else {
        std.log.info("TEST '{s}' ... FAIL", .{msg});
    }
}
