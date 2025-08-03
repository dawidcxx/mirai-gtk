const std = @import("std");
const Testing = @import("./testing.zig");

segments: []const Segment,
absolute: bool,

pub const FsPath = @This();
pub const Segment = []const u8;
pub const empty: FsPath = .{ .segments = &[_]FsPath.Segment{}, .absolute = false };

pub fn parent_dir(path: FsPath) FsPath {
    const all_but_last = path.segments[0 .. path.segments.len - 1];
    return .{ .segments = all_but_last, .absolute = path.absolute };
}

pub fn basename(path: FsPath) [:0]const u8 {
    const terminal = path.segments[path.segments.len - 1];
    var buf: [std.posix.NAME_MAX:0]u8 = undefined;
    @memcpy(buf[0..terminal.len], terminal);
    buf[terminal.len] = 0;
    return buf[0..terminal.len :0];
}

pub fn toString(self: FsPath, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    const buf = try allocator.alloc(u8, countSegmentLength(self) + getSeparatorCount(self));
    fmtPath(self, buf);
    return buf;
}

pub fn toStringZ(self: FsPath, allocator: std.mem.Allocator) error{OutOfMemory}![:0]const u8 {
    const len = countSegmentLength(self) + getSeparatorCount(self);
    const buf = try allocator.allocSentinel(u8, len, 0);
    fmtPath(self, buf);
    return buf;
}

pub fn fromStaticString(comptime path: []const u8) FsPath {
    const segments = comptime blk: {
        // Count non-empty segments first
        var segment_count: usize = 0;
        var it = std.mem.splitScalar(u8, path, '/');

        while (it.next()) |segment| {
            if (segment.len == 0) { // empty segment
                if (segment_count == 0) { // legal if it's the first segment
                    continue;
                } else {
                    @compileError("FsPath#fromStaticString: Illegal empty segment detected");
                }
            }
            segment_count += 1;
        }

        // Create the result array with exact size
        var segments: [segment_count][]const u8 = undefined;
        var count: usize = 0;
        it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| {
            if (segment.len > 0) {
                segments[count] = segment;
                count += 1;
            }
        }

        break :blk segments;
    };
    const is_absolute = comptime blk: {
        if (path.len > 0 and path[0] == '/') {
            break :blk true;
        } else {
            break :blk false;
        }
    };
    return .{ .segments = &segments, .absolute = is_absolute };
}

pub fn clone(path: FsPath, alloc: std.mem.Allocator) error{OutOfMemory}!FsPath {
    const segments_copy = try alloc.dupe(FsPath.Segment, path.segments);
    return .{
        .segments = segments_copy,
        .absolute = path.absolute,
    };
}

pub fn isAbsolute(path: FsPath) bool {
    return path.absolute;
}

pub fn isRelative(path: FsPath) bool {
    return !path.absolute;
}

// private utility fns

fn countSegmentLength(path: FsPath) usize {
    var sum: usize = 0;
    for (path.segments) |segment| sum += segment.len;
    return sum;
}

inline fn getSeparatorCount(path: FsPath) usize {
    return if (path.absolute) path.segments.len else if (path.segments.len > 0) path.segments.len - 1 else 0;
}

inline fn fmtPath(path: FsPath, buf: []u8) void {
    var pos: usize = 0;
    for (path.segments, 0..) |segment, i| {
        if (path.absolute or i > 0) {
            buf[pos] = '/';
            pos += 1;
        }
        @memcpy(buf[pos .. pos + segment.len], segment);
        pos += segment.len;
    }
}

// tests

test "run fromStaticString checks" {
    try Testing.run(fromStaticStringAbsoluteChecks);
    try Testing.run(fromStaticStringRelativeChecks);
}

fn fromStaticStringAbsoluteChecks(t: *Testing) anyerror!void {
    t.register(@src());
    const alloc = t.allocator;

    const path = FsPath.fromStaticString("/usr/local/bin");

    try t.isTrue("Path should be absolute", path.isAbsolute());
    try t.strEq("First segment should be usr", path.segments[0], "usr");
    try t.strEq("Second segment should be local", path.segments[1], "local");
    try t.strEq("Third segment should be bin", path.segments[2], "bin");

    const path_str = try path.toString(alloc);
    defer alloc.free(path_str);
    try t.strEq("Should render the path to a string correctly", path_str, "/usr/local/bin");
}

fn fromStaticStringRelativeChecks(t: *Testing) anyerror!void {
    t.register(@src());
    const alloc = t.allocator;

    const path = FsPath.fromStaticString(".config/nvim/init.lua");

    try t.isTrue("Path should be relative", path.isRelative());
    try t.strEq("First segment should be .config", path.segments[0], ".config");
    try t.strEq("Second segment should be nvim", path.segments[1], "nvim");
    try t.strEq("Third segment should be init.lua", path.segments[2], "init.lua");

    const path_str = try path.toStringZ(alloc);
    defer alloc.free(path_str);
    try t.strEq("Should render the path to a string correctly", path_str, ".config/nvim/init.lua");
}
