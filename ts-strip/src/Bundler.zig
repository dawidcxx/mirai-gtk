const std = @import("std");
const File = @import("./file.zig").File;
const ParserContext = @import("./parser.zig").ParserContext;
const FileParser = @import("./parser.zig").FileParser;
const Import = @import("./parser.zig").Import;

const Self = @This();

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
root_module_file: File,

module_map: std.StringHashMap(Module),
parser_ctx: ParserContext,

pub fn init(allocator: std.mem.Allocator, root_module_file: File) !Self {
    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_allocator = arena.allocator();

    const module_map = std.StringHashMap(Module).init(arena_allocator);
    const parser_ctx = try ParserContext.init(arena_allocator);

    return .{
        .allocator = arena_allocator,
        .arena = arena,
        .root_module_file = root_module_file,

        .module_map = module_map,
        .parser_ctx = parser_ctx,
    };
}

pub fn deinit(self: *Self) void {
    self.module_map.deinit();
    self.parser_ctx.deinit();
    self.arena.deinit();
}

pub fn bundle(self: *Self, output_file: File) !void {
    _ = output_file;

    const root_file_parser = try self.parser_ctx.forFile(self.root_module_file);
    const module: Module = .{ .file_parser = &root_file_parser };

    try self.module_map.put(self.root_module_file.realpath(self.allocator), module);
    try collectRecursive(&module, &self.module_map);
}

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

test "bundle basic test" {}
