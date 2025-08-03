const std = @import("std");
const Testing = @import("./testing.zig");

/// FsPath is a structured representation of a filesystem path
/// For example:
///  `{ segments: ["usr", "local", "bin"], absolute: true }` => `/usr/local/bin`
/// Use `FsPath.static` or `FsPath.Builder` to create instances
segments: []const Segment,
absolute: bool,

pub const FsPath = @This();
pub const Segment = []const u8;
pub const empty: FsPath = .{ .segments = &[_]FsPath.Segment{}, .absolute = false };

pub fn parentDir(path: FsPath) FsPath {
    const all_but_last = path.segments[0 .. path.segments.len - 1];
    return .{ .segments = all_but_last, .absolute = path.absolute };
}

pub fn basename(path: FsPath) error{InvalidPath}!Segment {
    if (path.segments.len == 0) {
        return error.InvalidPath;
    }
    return path.segments[path.segments.len - 1];
}

pub fn isAbsolute(path: FsPath) bool {
    return path.absolute;
}

pub fn isRelative(path: FsPath) bool {
    return !path.absolute;
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

pub fn deinit(self: FsPath, alloc: std.mem.Allocator) void {
    alloc.free(self.segments);
}

pub fn static(comptime path: []const u8) FsPath {
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

pub const Builder = struct {
    segments: std.ArrayListUnmanaged(Segment),
    backward_mode: bool,

    pub fn initForward(alloc: std.mem.Allocator, segment: Segment) error{OutOfMemory}!Builder {
        var segments = try std.ArrayListUnmanaged(Segment).initCapacity(alloc, 8);
        try segments.append(alloc, segment);
        return .{
            .segments = segments,
            .backward_mode = false,
        };
    }

    pub fn initBackward(alloc: std.mem.Allocator, segment: Segment) error{OutOfMemory}!Builder {
        var segments = try std.ArrayListUnmanaged(Segment).initCapacity(alloc, 8);
        try segments.append(alloc, segment);
        return .{
            .segments = segments,
            .backward_mode = true,
        };
    }

    pub fn push(self: *Builder, alloc: std.mem.Allocator, segment: Segment) error{OutOfMemory}!void {
        try self.segments.append(alloc, segment);
    }

    pub fn build_absolute(self: *Builder, alloc: std.mem.Allocator) error{OutOfMemory}!FsPath {
        const segments_owned = try self.segments.toOwnedSlice(alloc);
        if (self.backward_mode) {
            std.mem.reverse(Segment, segments_owned);
        }
        return .{
            .absolute = true,
            .segments = segments_owned,
        };
    }
};

// private utility fns
inline fn countSegmentLength(path: FsPath) usize {
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
    try Testing.run(validateAbsolutePaths);
    try Testing.run(validateRelativePaths);
    try Testing.run(validateRuntimePaths);
}

fn validateAbsolutePaths(t: *Testing) anyerror!void {
    t.register(@src());
    const alloc = t.allocator;

    const path = FsPath.static("/usr/local/bin");

    try t.isTrue("Path should be absolute", path.isAbsolute());
    try t.strEq("First segment should be usr", path.segments[0], "usr");
    try t.strEq("Second segment should be local", path.segments[1], "local");
    try t.strEq("Third segment should be bin", path.segments[2], "bin");

    const path_str = try path.toString(alloc);
    defer alloc.free(path_str);
    try t.strEq("Should render the path to a string correctly", path_str, "/usr/local/bin");
}

fn validateRelativePaths(t: *Testing) anyerror!void {
    t.register(@src());
    const alloc = t.allocator;

    const path = FsPath.static(".config/nvim/init.lua");

    try t.isTrue("Path should be relative", path.isRelative());
    try t.strEq("First segment should be .config", path.segments[0], ".config");
    try t.strEq("Second segment should be nvim", path.segments[1], "nvim");
    try t.strEq("Third segment should be init.lua", path.segments[2], "init.lua");

    const path_str = try path.toStringZ(alloc);
    defer alloc.free(path_str);
    try t.strEq("Should render the path to a string correctly", path_str, ".config/nvim/init.lua");
}

fn validateRuntimePaths(t: *Testing) anyerror!void {
    t.register(@src());
    const alloc = t.allocator;

    var builder = try FsPath.Builder.initBackward(alloc, "notes.txt");
    try builder.push(alloc, "dawid");
    try builder.push(alloc, "home");

    const path = try builder.build_absolute(alloc);
    defer path.deinit(alloc);

    const path_str = try path.toString(alloc);
    defer alloc.free(path_str);
    try t.strEq("FsPath#Builder should construct the path as expected", path_str, "/home/dawid/notes.txt");
}
