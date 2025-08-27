const std = @import("std");
const Testing = @import("./testing.zig");
const util = @import("./util.zig");

/// FsPath is a structured representation of a filesystem path
/// For example:
///  `{ segments: ["usr", "local", "bin"], absolute: true }` => `/usr/local/bin`
/// Use:
///  - `FsPath.static` example: FsPath.static("/home/foo"),
///  - `FsPath.Builder` to incrementally construct a path
///  - `FsPath.fromString` turn a string into FsPath
pub const FsPath = struct {
    pub const Segment = []const u8;

    pub const Hash = HashImpl;
    pub const Builder = BuilderImpl;

    pub const root: *const FsPath = &.{ .segments = &[_]FsPath.Segment{}, .absolute = true };
    pub const current_dir: *const FsPath = &.{ .segments = &[_]FsPath.Segment{}, .absolute = false };

    segments: []const Segment,
    absolute: bool,

    pub fn fromString(
        allocator: std.mem.Allocator,
        fspath_string_borrow: []const u8,
    ) !FsPath {
        var it = std.mem.splitScalar(u8, fspath_string_borrow, '/');

        var segment_count: usize = 0;
        while (it.next()) |segment| {
            if (isSegmentSkippable(segment)) continue;
            segment_count += 1;
        }

        var builder = try FsPath.Builder.initForward(allocator, segment_count);

        while (it.next()) |segment| {
            if (isSegmentSkippable(segment)) continue;
            try builder.push(allocator, segment);
        }
        if (std.mem.startsWith(u8, fspath_string_borrow, "/")) {
            return try builder.buildAbsolute(allocator);
        } else {
            return try builder.buildRelative(allocator);
        }
    }

    pub fn deinit(fspath_owned: FsPath, allocator: std.mem.Allocator) void {
        for (fspath_owned.segments) |segment| {
            allocator.free(segment);
        }
        allocator.free(fspath_owned.segments);
    }

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

    pub fn format(
        self: FsPath,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        return formatImpl(self, fmt, options, writer);
    }

    pub fn eql(path1: FsPath, path2: FsPath) bool {
        if (path1.segments.len != path2.segments.len) {
            return false;
        }
        if (path1.absolute != path2.absolute) {
            return false;
        }
        for (path1.segments, path2.segments) |seg1, seg2| {
            if (!std.mem.eql(u8, seg1, seg2)) {
                return false;
            }
        }
        return true;
    }

    pub fn static(comptime path: []const u8) FsPath {
        return fromStaticStringImpl(path);
    }
};

pub fn formatImpl(
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

const BuilderImpl = struct {
    segments: std.ArrayListUnmanaged(FsPath.Segment),
    backward_mode: bool,

    pub fn initForward(allocator: std.mem.Allocator, segment_count: usize) error{OutOfMemory}!BuilderImpl {
        const segments = try std.ArrayListUnmanaged(FsPath.Segment).initCapacity(
            allocator,
            segment_count,
        );
        return .{
            .segments = segments,
            .backward_mode = false,
        };
    }

    pub fn initBackward(allocator: std.mem.Allocator, segment_count: usize) error{OutOfMemory}!BuilderImpl {
        const segments = try std.ArrayListUnmanaged(FsPath.Segment).initCapacity(
            allocator,
            segment_count,
        );
        return .{
            .segments = segments,
            .backward_mode = true,
        };
    }

    pub fn push(self: *BuilderImpl, alloc: std.mem.Allocator, segment_borrow: FsPath.Segment) error{OutOfMemory}!void {
        const copy = try alloc.dupe(u8, segment_borrow);
        try self.segments.append(alloc, copy);
    }

    pub fn pushPath(self: *BuilderImpl, alloc: std.mem.Allocator, path_borrow: FsPath) error{OutOfMemory}!void {
        for (path_borrow.segments) |segment| {
            try self.push(alloc, segment);
        }
    }

    pub fn buildAbsolute(self: *BuilderImpl, alloc: std.mem.Allocator) error{OutOfMemory}!FsPath {
        return self.build(alloc, true);
    }

    pub fn buildRelative(self: *BuilderImpl, alloc: std.mem.Allocator) error{OutOfMemory}!FsPath {
        return self.build(alloc, false);
    }

    fn build(self: *BuilderImpl, alloc: std.mem.Allocator, is_absolute: bool) error{OutOfMemory}!FsPath {
        const segments_owned = try self.segments.toOwnedSlice(alloc);
        if (self.backward_mode) {
            std.mem.reverse(FsPath.Segment, segments_owned);
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
        return FsPath.eql(fs_path1, fs_path2);
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

fn fromStaticStringImpl(comptime path: []const u8) FsPath {
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

inline fn isSegmentSkippable(segment: []const u8) bool {
    if (segment.len == 0 or (segment[0] == '.' and segment.len == 1)) {
        return true;
    } else {
        return false;
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

    const root_str = try FsPath.root.toString(t.allocator);
    defer t.allocator.free(root_str);
    try t.strEq("Should render root path '/' correctly", root_str, "/");

    const path_copy_from_str = try FsPath.fromString(alloc, path_str);
    defer path_copy_from_str.deinit(alloc);

    std.log.debug("path='{s}' copy='{s}'", .{ path, path_copy_from_str });
    try t.isTrue("path copy should be as original", FsPath.eql(path, path_copy_from_str));
}

fn validateRelativePaths(t: *Testing) anyerror!void {
    t.register(@src());
    const alloc = t.allocator;

    const path = FsPath.static(".config/nvim/init.lua");

    try t.isTrue("Path should be relative", path.isRelative());
    try t.strEq("First segment should be .config", path.segments[0], ".config");
    try t.strEq("Second segment should be nvim", path.segments[1], "nvim");
    try t.strEq("Third segment should be init.lua", path.segments[2], "init.lua");

    const path_str = try path.toString(alloc);
    defer alloc.free(path_str);
    try t.strEq("Should render the path to a string correctly", path_str, "./.config/nvim/init.lua");

    const current_dir_str = try FsPath.current_dir.toString(alloc);
    defer alloc.free(current_dir_str);
    try t.strEq("Should render current_directory path as './'", current_dir_str, "./");
}

fn validateRuntimePaths(t: *Testing) anyerror!void {
    t.register(@src());
    const alloc = t.allocator;

    var builder = try FsPath.Builder.initBackward(alloc, 4);
    try builder.push(alloc, "notes.txt");
    try builder.push(alloc, "dawid");
    try builder.push(alloc, "home");

    const path = try builder.buildAbsolute(alloc);
    defer path.deinit(alloc);

    const path_str = try std.fmt.allocPrint(alloc, "{s}", .{path});
    defer alloc.free(path_str);
    try t.strEq("FsPath#Builder should construct the path as expected", path_str, "FsPath(absolute='yes' segments=['home','dawid','notes.txt'])");
}
