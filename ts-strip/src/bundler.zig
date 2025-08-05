const std = @import("std");
const Testing = @import("./testing.zig");
const ParserContext = @import("./parser.zig").ParserContext;
const FileParser = @import("./parser.zig").FileParser;
const Import = @import("./parser.zig").Import;
const Fs = @import("./fs.zig");
const FsPath = @import("./FsPath.zig");
const FileSystem = Fs.FileSystem;

const ModuleMap = std.ArrayHashMapUnmanaged(FsPath, *FileParser, FsPath.Hash, true);

// public interface
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

        var module_map: ModuleMap = .empty;
        defer module_map.deinit(alloc);

        var parser_ctx = try ParserContext.init(alloc);
        defer parser_ctx.deinit();

        var entry = try self.fs.open(entry_path);
        const entry_absolute_path = try entry.realpath();

        try collectModules(alloc, self.fs, &parser_ctx, &module_map, entry_absolute_path);
    }
};

// utility fns
fn collectModules(
    alloc: std.mem.Allocator,
    fs: *FileSystem,
    parser_ctx: *ParserContext,
    module_map: *ModuleMap,
    absolute_fs_path: FsPath,
) !void {
    if (module_map.get(absolute_fs_path)) |file_parser| {
        std.log.debug("module for file='{s}' parsed into source set", .{file_parser.file.toString()});
        return;
    } else {
        const file = try fs.open(absolute_fs_path);
        const absolute_path = (try file.realpath()).parentDir();
        const parser = try parser_ctx.forFile(file);
        try parser.parse();
        try module_map.put(alloc, absolute_path, parser);
        const imports = try parser.getReferencedImports();
        for (imports) |import| {
            if (import.isRelative()) {
                const import_path = try import.toPath(alloc);
                std.log.info("Resolving relative import '{s}' against '{s}'", .{ try import_path.toString(alloc), try absolute_path.toString(alloc) });
                const resolved_path = try fs.resolveRelative(alloc, absolute_path, import_path);
                try collectModules(alloc, fs, parser_ctx, module_map, resolved_path);
            } else {
                @panic("TODO: absolute imports");
            }
        }
    }
}

test "ts-strip/bundler basicBundlerTest" {
    try Testing.run(basicBundlerTest);
}

fn basicBundlerTest(t: *Testing) anyerror!void {
    t.register(@src());

    // Fixtures: begin
    const FILES: []const FsPath = &[_]FsPath{ FsPath.static("/main.ts"), FsPath.static("/math.ts") };
    const CONTENT: []const []const u8 = &[_][]const u8{
        "import { add } from './math';\nconsole.log(add(2, 3));",
        "export function add(a: number, b: number): number { return a + b; }\n",
    };
    // Fixtures: end
    var fs: FileSystem = try .ofVirtual(t.allocator);
    defer fs.destroy(t.allocator);

    var bundler: Bundler = .init(t.allocator, &fs);
    defer bundler.deinit();

    // Prepare disk structure
    for (FILES, CONTENT) |file, content| {
        try fs.create(file);
        var entry_file = try fs.open(file);
        defer entry_file.close();
        try entry_file.writeAll(content);
    }

    const output_path = FsPath.static("/bundle.out.js");
    try bundler.bundle(FsPath.static("/main.ts"), output_path);

    var output_file = try fs.open(output_path);
    defer output_file.close();
    const output_content = try output_file.readAll(t.allocator);
    defer t.allocator.free(output_content);

    const expected_output =
        \\ function add(a, b) { return a + b; }\n
        \\ console.log(add(2, 3));\n
    ;

    try t.strEq("Should bundle as expected", output_content, expected_output[0..]);
}
