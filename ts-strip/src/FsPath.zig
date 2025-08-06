const std = @import("std");
const Testing = @import("./testing.zig");
const util = @import("./util.zig");

/// FsPath is a structured representation of a filesystem path
/// For example:
///  `{ segments: ["usr", "local", "bin"], absolute: true }` => `/usr/local/bin`
/// Use `FsPath.static` or `FsPath.Builder` to create instances
segments: []const Segment,
absolute: bool,

pub const FsPath = @This();
pub const Segment = []const u8;
pub const root: FsPath = .{ .segments = &[_]FsPath.Segment{}, .absolute = true };
pub const current_dir: FsPath = .{ .segments = &[_]FsPath.Segment{}, .absolute = false };
pub const Hash = HashImpl;

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

pub fn format(
    self: FsPath,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    try writer.print("FsPath(", .{});
    {
        try writer.print("absolute='{s}' ", .{util.fmtBool(self.absolute)});
        try writer.print("segments=[", .{});
        for (self.segments, 0..) |segment, index| {
            try writer.print("'{s}'", .{segment});
            if (index != self.segments.len - 1) {
                try writer.print(",", .{});
            }
        }
        try writer.print("]", .{});
    }
    try writer.print(")", .{});
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

pub fn fromString(string: []const u8, allocator: std.mem.Allocator) !FsPath {
    var builder = try FsPath.Builder.initForward(allocator);
    var it = std.mem.splitScalar(u8, string, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or (segment[0] == '.' and segment.len == 1)) {
            continue; // skip empty segments
        }
        try builder.push(allocator, segment);
    }
    if (std.mem.startsWith(u8, string, "/")) {
        return try builder.buildAbsolute(allocator);
    } else {
        return try builder.buildRelative(allocator);
    }
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

    pub fn initForward(alloc: std.mem.Allocator) error{OutOfMemory}!Builder {
        const segments = try std.ArrayListUnmanaged(Segment).initCapacity(alloc, 8);
        return .{
            .segments = segments,
            .backward_mode = false,
        };
    }

    pub fn initBackward(alloc: std.mem.Allocator) error{OutOfMemory}!Builder {
        const segments = try std.ArrayListUnmanaged(Segment).initCapacity(alloc, 8);
        return .{
            .segments = segments,
            .backward_mode = true,
        };
    }

    pub fn push(self: *Builder, alloc: std.mem.Allocator, segment: Segment) error{OutOfMemory}!void {
        try self.segments.append(alloc, segment);
    }

    pub fn pushPath(self: *Builder, alloc: std.mem.Allocator, path: FsPath) error{OutOfMemory}!void {
        for (path.segments) |segment| {
            try self.push(alloc, segment);
        }
    }

    pub fn buildAbsolute(self: *Builder, alloc: std.mem.Allocator) error{OutOfMemory}!FsPath {
        return self.build(alloc, true);
    }

    pub fn buildRelative(self: *Builder, alloc: std.mem.Allocator) error{OutOfMemory}!FsPath {
        return self.build(alloc, false);
    }

    fn build(self: *Builder, alloc: std.mem.Allocator, is_absolute: bool) error{OutOfMemory}!FsPath {
        const segments_owned = try self.segments.toOwnedSlice(alloc);
        if (self.backward_mode) {
            std.mem.reverse(Segment, segments_owned);
        }
        return .{
            .absolute = is_absolute,
            .segments = segments_owned,
        };
    }
};

const HashImpl = struct {
    pub fn hash(self: HashImpl, key: FsPath) u32 {
        _ = self;
        const seed_n: u64 = if (key.isAbsolute()) 0xDEADBEEF else 0xBEEFDEAD;
        var hasher = std.hash.Wyhash.init(seed_n);
        for (key.segments) |segment| {
            hasher.update(segment);
        }
        return @truncate(hasher.final());
    }

    pub fn eql(self: HashImpl, fs_path1: FsPath, fs_path2: FsPath, index: usize) bool {
        _ = self;
        _ = index;
        if (fs_path1.segments.len != fs_path2.segments.len) {
            return false;
        }
        for (fs_path1.segments, fs_path2.segments) |seg1, seg2| {
            if (!std.mem.eql(u8, seg1, seg2)) {
                return false;
            }
        }
        return true;
    }
};

// private
inline fn countSegmentLength(path: FsPath) usize {
    var sum: usize = 0;
    for (path.segments) |segment| sum += segment.len;
    return sum;
}

inline fn getSeparatorCount(path: FsPath) usize {
    if (path.absolute) {
        return @max(1, path.segments.len);
    } else {
        return @max(1, path.segments.len) + 1;
    }
}

inline fn fmtPath(path: FsPath, buf: []u8) void {
    var pos: usize = 0;
    if (path.absolute) {
        buf[pos] = '/';
        pos += 1;
    } else {
        buf[pos] = '.';
        buf[pos + 1] = '/';
        pos += 2;
    }
    for (path.segments, 0..) |segment, i| {
        if (i > 0) {
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

    const root_str = try root.toString(t.allocator);
    defer t.allocator.free(root_str);
    try t.strEq("Should render root path '/' correctly", root_str, "/");
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
    try t.strEq("Should render the path to a string correctly", path_str, "./.config/nvim/init.lua");

    const current_dir_str = try current_dir.toString(alloc);
    defer alloc.free(current_dir_str);
    try t.strEq("Should render current_directory path as './'", current_dir_str, "./");
}

fn validateRuntimePaths(t: *Testing) anyerror!void {
    t.register(@src());
    const alloc = t.allocator;

    var builder = try FsPath.Builder.initBackward(alloc);
    try builder.push(alloc, "notes.txt");
    try builder.push(alloc, "dawid");
    try builder.push(alloc, "home");

    const path = try builder.buildAbsolute(alloc);
    defer path.deinit(alloc);

    const path_str = try std.fmt.allocPrint(alloc, "{s}", .{path});
    defer alloc.free(path_str);
    try t.strEq("FsPath#Builder should construct the path as expected", path_str, "FsPath(absolute='yes' segments=['home','dawid','notes.txt'])");
}
