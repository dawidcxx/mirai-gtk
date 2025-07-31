const std = @import("std");
const sys = @import("std").os.linux;
const Testing = @import("./testing.zig");
const utils = @import("./util.zig");
const builtin = @import("builtin");

const MAX_FILE_SIZE: usize = 1024 * 1024 * 5; // 5 MB

pub const File = struct {
    fd: i32,
    name: [:0]const u8,
    is_virtual: bool = false,

    pub fn virtual(file_name: [:0]const u8) File {
        const fd = sys.memfd_create(file_name, 0);
        if (fd == -1) {
            std.debug.panic("Unexpected File#virtual error, failed to memfd_create for '{s}', returned = {d}", .{ file_name, fd });
        }
        return .{ .fd = @intCast(fd), .name = file_name, .is_virtual = true };
    }

    pub fn open(file_name: [:0]const u8) File {
        const fd = sys.open(file_name, sys.O_RDWR | sys.O_CREAT | sys.O_TRUNC, 0o644);
        if (fd != 0) {
            std.debug.panic("Unexpected File#open error, failed to open '{s}', returned = {d}", .{ file_name, fd });
        }
        return .{ .fd = @intCast(fd), .name = file_name };
    }

    pub fn write(self: File, content: []const u8) void {
        if (builtin.is_test) {
            std.log.debug("Writing to file = '{s}' with content = '{s}'", .{ self.name, content });
        }
        const std_file: std.fs.File = .{ .handle = self.fd };
        std_file.writeAll(content) catch |e| {
            std.debug.panic("Unexpected File#write error, failed to write to '{s}': '{}'", .{ self.name, e });
        };
    }

    pub fn read(self: File, allocator: std.mem.Allocator) ![]u8 {
        const std_file: std.fs.File = .{ .handle = self.fd };
        std_file.seekTo(0) catch |e| {
            std.debug.panic("Unexpected File#read error, failed to seek to beginning of '{s}': '{}'", .{ self.name, e });
        };
        const content = try std_file.reader().readAllAlloc(allocator, MAX_FILE_SIZE);
        return content;
    }

    pub fn realpath(self: File, allocator: std.mem.Allocator) ![:0]const u8 {
        const proc_path = try std.fmt.allocPrintZ(allocator, "/proc/self/fd/{d}", .{self.fd});
        if (self.is_virtual) {
            // virtual files have no physical location
            // best we can do is return the loopback proc fd
            return proc_path;
        }

        defer allocator.free(proc_path);

        var buf = try allocator.alloc(u8, std.os.linux.NAME_MAX);
        errdefer allocator.free(buf);

        const written = std.os.linux.readlink(proc_path, buf.ptr, buf.len);
        if (written == -1) {
            return error.ReadLinkFailed;
        }
        buf = try allocator.realloc(buf, written);
        buf[written + 1] = 0;
        return @ptrCast(buf);
    }

    pub fn close(self: File) void {
        _ = sys.close(self.fd);
    }
};

test "basic run test" {
    try Testing.run(fileBasicTest);
}

fn fileBasicTest(testing: *Testing) anyerror!void {
    testing.register(@src());
    testing.setLogLevel(.info);

    var file: File = .virtual("some_vfs_file.sh");
    defer file.close();
    std.log.debug("File created: {s} with fd = '{d}'", .{ file.name, file.fd });

    const file_content =
        \\ #!/bin/sh
        \\ echo "Hello, world!" > /dev/null
    ;
    file.write(file_content[0..]);

    const read_content = try file.read(testing.allocator);
    defer testing.allocator.free(read_content);

    try testing.strEq(file_content[0..], read_content);

    const realpath = try file.realpath(testing.allocator);
    defer testing.allocator.free(realpath);

    std.log.info("Real path of file: {s}", .{realpath});
}
