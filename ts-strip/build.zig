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

    const root_mod = mkModule(b, .{
        .name = "ts-strip",
        .src = b.path("./src/root.zig"),
        .tree_sitter_dep = tree_sitter,
        .tree_sitter_lib = typescript_grammar_lib,
        .optimize = optimize,
        .target = target,
    });
    const root_mod_test = mkTest(b, .{ .mod = root_mod, .target = target });
    const bundler_mod = mkModule(b, .{
        .name = "ts-strip/bundler",
        .src = b.path("./src/bundler.zig"),
        .tree_sitter_dep = tree_sitter,
        .tree_sitter_lib = typescript_grammar_lib,
        .optimize = optimize,
        .target = target,
    });
    const bundler_mod_test = mkTest(b, .{ .mod = bundler_mod, .target = target });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&bundler_mod_test.step);
    test_step.dependOn(&root_mod_test.step);
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
