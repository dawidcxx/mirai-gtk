const std = @import("std");
const Testing = @import("./testing.zig");
const ParserContext = @import("./parser.zig").ParserContext;
const FileParser = @import("./parser.zig").FileParser;
const Import = @import("./parser.zig").Import;
const Fs = @import("./fs.zig");

const FileSystem = Fs.FileSystem;
const File = Fs.File;
const FsPath = Fs.FsPath;

pub const Bundler = struct {
    const Self = @This();

    arena: std.heap.ArenaAllocator,
    fs: *FileSystem,

    pub fn init(alloc: std.mem.Allocator, fs: *FileSystem) Self {
        const arena = std.heap.ArenaAllocator.init(alloc);
        return .{
            .arena = arena,
            .fs = fs,
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn bundle(self: *Self, entry_path: FsPath, output_path: FsPath) !void {
        _ = output_path;

        const alloc = self.arena.allocator();

        var module_map: std.StringHashMapUnmanaged(*FileParser) = .empty;
        defer module_map.deinit(alloc);

        var parser_ctx = try ParserContext.init(alloc);
        defer parser_ctx.deinit();

        var entry = try self.fs.open(entry_path);

        try module_map.put(alloc, entry.toString(), try parser_ctx.forFile(entry));
    }
};

const Module = struct {
    file_parser: *FileParser,

    inline fn isParsed(self: Module) bool {
        return self.file_parser.isParsed();
    }

    inline fn parse(self: Module) !void {
        try self.file_parser.parse();
    }

    inline fn getImports(self: Module) ![]Import {
        return self.file_parser.getReferencedImports();
    }

    inline fn getPathId(self: Module, allocator: std.mem.Allocator, import: Import) ![]const u8 {
        _ = self;
        _ = allocator;
        _ = import;
        return error.NotImplemented;
    }
};

fn collectRecursive(allocator: std.mem.Allocator, module: *Module, out_map: *std.StringHashMap(Module)) !void {
    if (module.isParsed()) {
        @panic("Recursive modules aren't handled yet");
    } else {
        try module.parse(); // todo: better error handling
        for (try module.getImports()) |import| {
            const module_path_id = try module.getPathId(allocator, import);
            if (!out_map.contains(module_path_id)) {
                @panic("RIP");
            }
        }
    }
    return error.NotImplemented;
}

test "run basicBundlerTest" {
    try Testing.run(basicBundlerTest);
}

fn basicBundlerTest(ctx: *Testing) anyerror!void {
    ctx.register(@src());

    // Fixtures: begin
    const MAIN_ENTRY = .{
        @as(FsPath, &[_][:0]const u8{"main.ts"}),
        @as([]const u8, 
            \\ import { max } from './utils/math';
            \\ import { fs } from '@mirai-gtk/core';
            \\ console.log(max(2,4));
            \\
        ),
    };
    const UTILS = .{
        @as(FsPath, &[_][:0]const u8{ "utils", "math.ts" }), @as([]const u8, 
            \\ export function max(...args: number[]) { 
            \\    throw new Error('Not implemented');
            \\ }
        ),
    };
    const TS_SOURCES = [_]struct { FsPath, []const u8 }{
        MAIN_ENTRY,
        UTILS,
    };
    const OUT_FILE = &[_][:0]const u8{"bundle.js"};
    // Fixtures: end

    var fs: FileSystem = try .ofVirtual(ctx.allocator);
    defer fs.destroy(ctx.allocator);

    var bundler: Bundler = .init(ctx.allocator, &fs);
    defer bundler.deinit();

    // Prepare disk structure
    for (TS_SOURCES) |file| {
        const path = file.@"0";
        const content = file.@"1";
        try fs.create(path);
        var entry_file = try fs.open(path);
        defer entry_file.close();
        try entry_file.writeAll(content);
    }

    try bundler.bundle(MAIN_ENTRY.@"0", OUT_FILE);
}
