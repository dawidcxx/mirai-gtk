const std = @import("std");
const posix = @import("std").posix;
const builtin = @import("builtin");
const Testing = @import("./testing.zig");
const FsPath = @import("./FsPath.zig");

pub const FsError = error{ OutOfMemory, InvalidPath, IOError };

pub const File = struct {
    // Guaranteed to be unique for each given file
    // regardless of the path i.e foo.txt == ./baz/../foo.txt
    id: usize,

    fs: FileSystem,

    pub fn realpath(self: File) FsError!FsPath {
        return self.fs.realpath(self);
    }

    pub fn toString(self: *File) []const u8 {
        return self.fs.toString(self.*);
    }

    pub fn close(self: *File) void {
        self.fs.close(self);
    }

    pub fn writeAll(self: *File, content: []const u8) FsError!void {
        return self.fs.writeAll(self, content);
    }

    pub fn readAll(self: File, alloc: std.mem.Allocator) FsError![]u8 {
        return self.fs.readAll(self, alloc);
    }
};

pub const FileSystem = union(enum) {
    Virtual: *VirtualFs,
    Real: *RealFs,

    pub fn ofVirtual(alloc: std.mem.Allocator) !FileSystem {
        const virtual_fs = try alloc.create(VirtualFs);
        virtual_fs.* = try VirtualFs.init(alloc);
        return .{ .Virtual = virtual_fs };
    }

    pub fn ofReal(alloc: std.mem.Allocator) !FileSystem {
        const real_fs = try alloc.create(RealFs);
        real_fs.* = RealFs.init(alloc);
        return .{ .Real = real_fs };
    }

    pub fn destroy(self: FileSystem, alloc: std.mem.Allocator) void {
        switch (self) {
            inline else => |impl| {
                impl.deinit();
                alloc.destroy(impl);
            },
        }
    }

    pub fn realpath(self: FileSystem, file: File) FsError!FsPath {
        switch (self) {
            inline else => |fs| return fs.realpath(file),
        }
    }

    pub fn writeAll(self: *FileSystem, file: File, content: []const u8) FsError!void {
        switch (self.*) {
            inline else => |fs| return fs.writeAll(file, content),
        }
    }

    pub fn readAll(self: *FileSystem, file: File, alloc: std.mem.Allocator) FsError![]u8 {
        switch (self.*) {
            inline else => |fs| return fs.readAll(file, alloc),
        }
    }

    pub fn close(self: *FileSystem, file: File) void {
        switch (self.*) {
            inline else => |fs| fs.close(file),
        }
    }

    pub fn open(self: *FileSystem, file_path: FsPath) FsError!File {
        switch (self.*) {
            inline else => |fs| fs.open(file_path),
        }
    }

    pub fn create(self: *FileSystem, file_path: FsPath) FsError!void {
        switch (self.*) {
            inline else => |fs| fs.create(file_path),
        }
    }

    pub fn rm(self: *FileSystem, file_path: FsPath) FsError!void {
        switch (self.*) {
            inline else => |fs| fs.rm(file_path),
        }
    }

    pub fn mkDir(self: *FileSystem, dir_path: FsPath) FsError!void {
        switch (self.*) {
            inline else => |fs| fs.mkDir(dir_path),
        }
    }

    pub fn resolveRelative(self: *FileSystem, context: FsPath, appendix: FsPath) FsError!*VirtualFsNode {
        switch (self.*) {
            inline else => |fs| return fs.resolveRelative(context, appendix),
        }
    }

    pub fn toString(self: *FileSystem, file: File) []const u8 {
        switch (self.*) {
            inline else => |fs| return fs.toString(file),
        }
    }
};

pub const VirtualFs = struct {
    const FileId = usize;

    arena: std.heap.ArenaAllocator,
    disk: *VirtualFsNode,

    // metadata-like fields
    opened_file_paths: std.AutoHashMapUnmanaged(FileId, FsPath),
    to_string_cache: std.AutoArrayHashMapUnmanaged(FileId, []const u8),

    pub fn init(allocator: std.mem.Allocator) !VirtualFs {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const arena_allocator = arena.allocator();

        const root_entries = std.ArrayListUnmanaged(*VirtualFsNode).initCapacity(arena_allocator, 16) catch unreachable;
        const disk = try arena_allocator.create(VirtualFsNode);
        disk.* = .{ .Dir = .{ .name = "@ROOT", .children = root_entries, .parent = null } };

        const opened_file_paths: std.AutoHashMapUnmanaged(FileId, FsPath) = .empty;
        const to_string_cache: std.AutoArrayHashMapUnmanaged(FileId, []const u8) = .empty;

        return .{ .arena = arena, .disk = disk, .opened_file_paths = opened_file_paths, .to_string_cache = to_string_cache };
    }

    pub fn deinit(self: *VirtualFs) void {
        self.arena.deinit();
    }

    pub fn open(self: *VirtualFs, file_path: FsPath) FsError!File {
        const file_node = try self.disk.resolvePath(file_path);

        // If we find the entry we wanna own the path
        // to avoid any potential memory complications
        const alloc = self.arena.allocator();
        const file_path_owned = try file_path.clone(alloc);

        // (ab)using the address as the ID
        const file_id: usize = @intFromPtr(file_node);

        // keep track of the file's filepath
        try self.opened_file_paths.put(alloc, file_id, file_path_owned);

        const file: File = .{ .fs = .{ .Virtual = self }, .id = file_id };

        return file;
    }

    pub fn writeAll(self: *VirtualFs, file: File, content: []const u8) FsError!void {
        const fs_node = self.resolveFile(file) catch |e| {
            std.log.debug("Unable to resolve file to writeAll call, file may have been deleted", .{});
            return e;
        };
        const std_file: std.fs.File = .{ .handle = fs_node.File.fd };

        // Use pwriteAll to write at offset 0 without affecting file position
        std_file.pwriteAll(content, 0) catch |e| {
            std.log.debug("IOError '{s}' while trying to write to '{s}'", .{ @errorName(e), fs_node.name() });
            return FsError.IOError;
        };
    }

    pub fn readAll(self: *VirtualFs, file: File, alloc: std.mem.Allocator) FsError![]u8 {
        const fs_node = self.resolveFile(file) catch |e| {
            std.log.debug("Unable to resolve file to readAll call, file may have been deleted", .{});
            return e;
        };
        const std_file: std.fs.File = .{ .handle = fs_node.File.fd };
        // Get file size first
        const file_size = std_file.getEndPos() catch |e| {
            std.log.debug("IOError '{s}' while trying to get size of '{s}'", .{ @errorName(e), fs_node.name() });
            return FsError.IOError;
        };
        // Allocate buffer for the entire file
        const buf = try alloc.alloc(u8, file_size);
        errdefer alloc.free(buf);
        // Use preadAll to read from offset 0 without affecting file position
        _ = std_file.preadAll(buf, 0) catch |e| {
            std.log.debug("IOError '{s}' while trying to read file '{s}'", .{ @errorName(e), fs_node.name() });
            return FsError.IOError;
        };
        return buf;
    }

    pub fn close(self: *VirtualFs, file: File) void {
        if (!self.opened_file_paths.swapRemove(file.id)) {
            @panic("VirtFs#close called on a already closed or not opened file");
        }
    }

    pub fn realpath(self: *VirtualFs, file: File) FsError!FsPath {
        if (self.opened_file_paths.get(file.id)) |fs_path| {
            return fs_path;
        } else {
            return FsError.InvalidPath;
        }
    }

    pub fn toString(self: *VirtualFs, file: File) []const u8 {
        if (self.to_string_cache.get(file.id)) |to_string_cached| {
            return to_string_cached;
        }
        const path = self.realpath(file) catch {
            std.log.err("VirtuaFs#toString unable to resolve File(id='{d}') real path", .{file.id});
            return "FILE_GONE";
        };
        const allocator = self.arena.allocator();
        const result = path.toString(allocator) catch {
            std.log.err("VirtuaFs#toString not enough memory to format string", .{});
            return "FILE_GONE";
        };
        self.to_string_cache.put(allocator, file.id, result) catch {
            std.log.err("VirtuaFs#toString not enough memory to cache string", .{});
            return result;
        };
        return result;
    }

    // resolveRelative /home/foo/Pictures Cat.jpg => VirtualFsNode {/home/foo/Pictures/Cat.jpg}
    // NOTE: context must be absolute path
    pub fn resolveRelative(self: *VirtualFs, context: FsPath, appendix: FsPath) FsError!*VirtualFsNode {
        const prefix = try self.disk.resolvePath(context);
        return try prefix.resolvePath(appendix);
    }

    pub fn create(self: *VirtualFs, path: FsPath) FsError!void {
        const file_name = path.basename();
        const file_parent_path = path.parent_dir();

        const parent_dir = try self.disk.resolvePath(file_parent_path);

        const fd = posix.memfd_createZ(file_name, 0) catch unreachable;

        const allocator = self.arena.allocator();
        const file_entry = try allocator.create(VirtualFsNode);

        file_entry.* = .{ .File = .{ .name = file_name, .fd = @intCast(fd), .parent = parent_dir } };

        try parent_dir.Dir.children.append(allocator, file_entry);
    }

    pub fn rm(self: *VirtualFs, file_path: []const FsPath.Segment) FsError!void {
        const INDEX_NOT_FOUND: usize = std.math.maxInt(usize);

        const name = file_path[file_path.len - 1];
        const path = file_path[0 .. file_path.len - 1];
        std.log.debug("VirtFs#rm: name={s} path={s}", .{ name, path });

        const parent = try self.disk.resolvePath(path);

        var found: usize = INDEX_NOT_FOUND;
        for (parent.Dir.children.items, 0..) |dir_entry, index| {
            switch (dir_entry.*) {
                .Dir => {},
                .File => |dir_file_entry| {
                    if (std.mem.eql(u8, dir_file_entry.name, name)) {
                        std.log.debug("VirtFs#rm removing {s}/{s} index={d}", .{ path, name, index });
                        found = index;
                        posix.close(dir_file_entry.fd);
                        break;
                    }
                },
            }
        }

        if (found == INDEX_NOT_FOUND) {
            return FsError.InvalidPath;
        }

        const file_node = parent.Dir.children.orderedRemove(found);
        self.arena.allocator().destroy(file_node);
    }

    pub fn mkDir(self: *VirtualFs, path_segments: FsPath) FsError!void {
        const allocator = self.arena.allocator();

        const name = path_segments.basename();
        const path = path_segments.parent_dir();

        if (builtin.mode == .Debug) {
            const path_str = try path.toString(allocator);
            defer allocator.free(path_str);
            std.log.debug("VirtFs#mkdir: name={s} path={s}", .{
                name,
                path_str,
            });
        }

        const parent_dir = try self.disk.resolvePath(path);

        const dir_children_list = try std.ArrayListUnmanaged(*VirtualFsNode).initCapacity(allocator, 4);
        const new_dir_entry = try allocator.create(VirtualFsNode);
        new_dir_entry.* = .{ .Dir = .{ .name = name, .children = dir_children_list, .parent = parent_dir } };

        try parent_dir.Dir.children.append(allocator, new_dir_entry);
    }

    pub fn stat(self: *VirtualFs) VirtualFsStats {
        const opened_file_count = self.opened_file_paths.count();
        const allocated_file_count = self.disk.fileCount();
        return .{ .opened_files_count = opened_file_count, .allocated_file_count = allocated_file_count };
    }

    fn resolveFile(self: *VirtualFs, file: File) FsError!*VirtualFsNode {
        const node_path: FsPath = try self.realpath(file);
        const fs_node = self.disk.resolvePath(node_path) catch unreachable;
        return fs_node;
    }
};

pub const VirtualFsNode = union(enum) {
    File: struct { name: FsPath.Segment, fd: std.posix.fd_t, parent: *VirtualFsNode },
    Dir: struct { name: FsPath.Segment, children: std.ArrayListUnmanaged(*VirtualFsNode), parent: ?*VirtualFsNode },

    pub fn name(self: VirtualFsNode) FsPath.Segment {
        return switch (self) {
            inline else => |it| it.name,
        };
    }

    pub fn fileCount(self: *VirtualFsNode) usize {
        switch (self.*) {
            .File => |file| {
                std.log.debug("Counting File (name='{s}')", .{file.name});
                return 1;
            },
            .Dir => |dir| {
                var count: usize = 0;
                std.log.debug("Counting Dir child_count = {d}", .{dir.children.items.len});
                for (dir.children.items) |item| {
                    std.log.debug("In dir {s} list {d}", .{ dir.name, dir.children.items.len });
                    count += item.fileCount();
                }
                return count;
            },
        }
    }

    pub fn resolvePath(root: *VirtualFsNode, path: FsPath) FsError!*VirtualFsNode {
        var it = root;

        for (path.segments) |path_segment| {
            if (std.mem.eql(u8, ".", path_segment)) {
                continue;
            }

            if (std.mem.eql(u8, "..", path_segment)) {
                const parent = switch (it.*) {
                    .Dir => |dir| dir.parent,
                    .File => {
                        std.log.debug("Tried to get the parent path of a file(name='{s}')", .{it.name()});
                        return FsError.InvalidPath;
                    },
                } orelse {
                    std.log.debug("Tried to get parent path but already at root", .{});
                    return FsError.InvalidPath;
                };
                it = parent;
                continue;
            }

            switch (it.*) {
                .File => |file| {
                    if (std.mem.eql(u8, file.name, path_segment)) {
                        continue;
                    } else {
                        return FsError.InvalidPath;
                    }
                },
                .Dir => |dir| {
                    var found = false;

                    // try find file
                    for (dir.children.items) |dir_entry| {
                        if (std.mem.eql(u8, dir_entry.name(), path_segment)) {
                            it = dir_entry;
                            found = true;
                            break;
                        }
                    }

                    if (!found) {
                        std.log.debug("Unable to resolve path, missing '{s}' in dir '{s}'", .{ path_segment, it.name() });
                        return FsError.InvalidPath;
                    }
                },
            }
        }

        return it;
    }
};

const VirtualFsStats = struct { opened_files_count: usize, allocated_file_count: usize };

const RealFs = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(alloc: std.mem.Allocator) RealFs {
        const arena = std.heap.ArenaAllocator.init(alloc);
        return .{ .arena = arena };
    }

    pub fn create(self: *RealFs, path_segments: FsPath) void!FsError {
        _ = self;
        _ = path_segments;
        @panic("Not implemented");
    }

    pub fn rm(self: *RealFs, file_path: FsPath) FsError!void {
        _ = self;
        _ = file_path;
        @panic("Not implemented");
    }

    pub fn mkDir(self: *RealFs, file_path: FsPath) FsError!void {
        _ = self;
        _ = file_path;
        @panic("Not implemented");
    }

    pub fn realpath(self: *RealFs, file: File) FsError!FsPath {
        _ = self;
        _ = file;
        @panic("Not implemented");
    }

    pub fn open(self: *RealFs, file_path: FsPath) FsError!FsPath {
        _ = self;
        _ = file_path;
        @panic("Not implemented");
    }

    pub fn close(self: *RealFs, file: File) void {
        _ = self;
        _ = file;
        @panic("Not implemented");
    }

    pub fn toString(self: *RealFs, file: File) []const u8 {
        _ = self;
        _ = file;
        @panic("Not implemented");
    }

    pub fn resolveRelative(self: *RealFs, context: FsPath, appendix: FsPath) FsError!*VirtualFsNode {
        _ = self;
        _ = context;
        _ = appendix;
        @panic("Not implemented");
    }

    pub fn writeAll(self: *RealFs, file: File, content: []const u8) FsError!void {
        _ = self;
        _ = file;
        _ = content;
        @panic("Not implemented");
    }

    pub fn readAll(self: *RealFs, file: File, alloc: std.mem.Allocator) FsError![]u8 {
        _ = self;
        _ = file;
        _ = alloc;
        @panic("Not implemented");
    }

    pub fn deinit(self: RealFs) void {
        self.arena.deinit();
    }
};

test "run virtualFsCheck" {
    try Testing.run(virtualFsCheck);
}

fn virtualFsCheck(t: *Testing) anyerror!void {
    t.register(@src());
    // t.setLogLevel(.debug);

    var fs: VirtualFs = try .init(t.allocator);
    defer fs.deinit();

    try fs.mkDir(FsPath.fromStaticString("/home"));
    try fs.mkDir(FsPath.fromStaticString("/home/dawid"));
    try fs.create(FsPath.fromStaticString("/home/dawid/.bashrc"));
    try fs.create(FsPath.fromStaticString("/home/dawid/.xinitrc"));
    try fs.create(FsPath.fromStaticString("/home/dawid/.history"));

    var file = try fs.open(FsPath.fromStaticString("/home/../home/dawid/.bashrc"));
    try t.sliceEq("File#realpath should get resolved, absolute path", (try file.realpath()).segments, FsPath.fromStaticString("/home/dawid/.bashrc").segments);

    const stats = fs.stat();
    try t.expectEqual("Should have 1 file opened", 1, stats.opened_files_count);
    try t.expectEqual("Should have 2 files in total", 2, stats.allocated_file_count);

    // Add /home/dawid/Pictures/Cat.jpg
    try fs.mkDir(FsPath.fromStaticString("/home/dawid/Pictures"));
    try fs.create(FsPath.fromStaticString("/home/dawid/Pictures/Cat.jpg"));

    // Resolves Cat.jpg from /home/dawid/Pictures
    const cat_picture = try fs.resolveRelative(FsPath.fromStaticString("/home/dawid/Pictures"), FsPath.fromStaticString("Cat.jpg"));
    try t.strEq("resolveRelative should default lookup entries in context dir", cat_picture.File.name, "Cat.jpg");

    // Fails resolve Cat.jpg from /home/dawid
    const not_cat_picture = fs.resolveRelative(FsPath.fromStaticString("/home/dawid"), FsPath.fromStaticString("Cat.jpg"));
    try t.expectEqual("resolveRelative should not resolve entries on the wrong level", not_cat_picture, FsError.InvalidPath);

    // Resolves /nix from /home/dawid/Pictures
    try fs.mkDir(FsPath.fromStaticString("/nix"));
    const nix_dir = try fs.resolveRelative(FsPath.fromStaticString("/home/dawid/Pictures"), FsPath.fromStaticString("./../../nix"));
    try t.strEq("resolveRelative should handle . and .. expressions", nix_dir.Dir.name, "nix");

    //  Try to get Cat.jpg through a round-about path
    const cat_picture_again = try fs.resolveRelative(FsPath.empty, FsPath.fromStaticString("home/../home/dawid/./Pictures/Cat.jpg"));
    try t.strEq("resolveRelative should handle round-about paths", cat_picture_again.File.name, "Cat.jpg");

    // FsPath: /home/dawid/notes.txt
    // Read/Write checks
    try fs.create(FsPath.fromStaticString("/home/dawid/notes.txt"));
    var notes_file = try fs.open(FsPath.fromStaticString("/home/dawid/notes.txt"));
    try fs.writeAll(notes_file, "1. Ship the project\n");
    const notes_content1 = try fs.readAll(notes_file, t.allocator);
    defer t.allocator.free(notes_content1);
    try t.strEq("Should read the content of notes.txt", notes_content1, "1. Ship the project\n");

    // Make sure we don't use seek based I/O
    const notes_content2 = try fs.readAll(notes_file, t.allocator);
    defer t.allocator.free(notes_content2);
    try t.strEq("Should read the content of notes.txt again", notes_content2, notes_content1);

    // toString check
    try t.strEq("toString() should render as expected", notes_file.toString(), "/home/dawid/notes.txt");

    const nix_cfg_file_path = FsPath.fromStaticString("/etc/nixos/configuration.nix");
    try t.strEq("Should render FsPath as expected", try nix_cfg_file_path.toString(t.allocator), "/etc/nixos/configuration.nix");
}
