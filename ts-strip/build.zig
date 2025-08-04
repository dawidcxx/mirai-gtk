const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tree_sitter_core_dep = b.dependency("tree_sitter_core", .{
        .target = target,
        .optimize = optimize,
    });

    const typescript_grammar_lib = b.addStaticLibrary(.{
        .name = "tree-sitter-typescript",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    typescript_grammar_lib.addIncludePath(b.path("c/"));
    typescript_grammar_lib.addIncludePath(b.path("c/tree_sitter"));
    typescript_grammar_lib.addCSourceFile(.{ .file = b.path("c/parser.c") });
    typescript_grammar_lib.addCSourceFile(.{ .file = b.path("c/scanner.c") });
    typescript_grammar_lib.linkLibrary(tree_sitter_core_dep.artifact("tree-sitter"));

    const tree_sitter = b.dependency("tree_sitter", .{
        .optimize = optimize,
        .target = target,
    });

    const module_factory = ModuleFactory{
        .b = b,
        .tree_sitter_dep = tree_sitter,
        .tree_sitter_lib = typescript_grammar_lib,
        .optimize = optimize,
        .target = target,
    };

    const root_mod = module_factory.createModule("ts-strip", "./src/root.zig");
    const root_mod_test = module_factory.createTest(root_mod);

    const bundler_mod = module_factory.createModule("ts-strip/bundler", "./src/bundler.zig");
    const bundler_mod_test = module_factory.createTest(bundler_mod);

    const parser_mod = module_factory.createModule("ts-strip/parser", "./src/parser.zig");
    const parser_mod_test = module_factory.createTest(parser_mod);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&bundler_mod_test.step);
    test_step.dependOn(&root_mod_test.step);
    test_step.dependOn(&parser_mod_test.step);

    const test_parser_step = b.step("test-parser", "Run parser tests only");
    test_parser_step.dependOn(&parser_mod_test.step);
}

const MkTestOptions = struct { mod: *std.Build.Module, target: std.Build.ResolvedTarget };

fn mkTest(b: *std.Build, opts: MkTestOptions) *std.Build.Step.Run {
    const compile = b.addTest(.{
        .root_module = opts.mod,
        .target = opts.target,
        .optimize = .Debug,
    });
    const runner = b.addRunArtifact(compile);
    return runner;
}

const MkModuleOptions = struct {
    name: []const u8,
    src: std.Build.LazyPath,
    tree_sitter_dep: *std.Build.Dependency,
    tree_sitter_lib: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

fn mkModule(b: *std.Build, opts: MkModuleOptions) *std.Build.Module {
    const mod = b.addModule(opts.name, .{ .root_source_file = opts.src, .optimize = opts.optimize, .target = opts.target });

    mod.addImport("tree-sitter", opts.tree_sitter_dep.module("tree-sitter"));
    mod.linkLibrary(opts.tree_sitter_lib);

    return mod;
}

const ModuleFactory = struct {
    b: *std.Build,
    tree_sitter_dep: *std.Build.Dependency,
    tree_sitter_lib: *std.Build.Step.Compile,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,

    fn createModule(self: ModuleFactory, name: []const u8, src_path: []const u8) *std.Build.Module {
        return mkModule(self.b, .{
            .name = name,
            .src = self.b.path(src_path),
            .tree_sitter_dep = self.tree_sitter_dep,
            .tree_sitter_lib = self.tree_sitter_lib,
            .optimize = self.optimize,
            .target = self.target,
        });
    }

    fn createTest(self: ModuleFactory, mod: *std.Build.Module) *std.Build.Step.Run {
        return mkTest(self.b, .{ .mod = mod, .target = self.target });
    }
};
