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

    const test_step = b.step("test", "Run tests");

    var module_factory = ModuleFactory.init(b, .{
        .tree_sitter_dep = tree_sitter,
        .tree_sitter_lib = typescript_grammar_lib,
        .optimize = optimize,
        .target = target,
        .test_step = test_step,
    });

    _ = module_factory.add("ts-strip", "./src/root.zig");
    _ = module_factory.add("ts-strip/bundler", "./src/bundler.zig");
    _ = module_factory.add("ts-strip/parser", "./src/parser.zig");
}

const ModuleFactoryOptions = struct {
    tree_sitter_dep: *std.Build.Dependency,
    tree_sitter_lib: *std.Build.Step.Compile,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    test_step: *std.Build.Step,
};

const ModuleFactory = struct {
    b: *std.Build,
    tree_sitter_dep: *std.Build.Dependency,
    tree_sitter_lib: *std.Build.Step.Compile,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    test_step: *std.Build.Step,

    pub fn init(b: *std.Build, opts: ModuleFactoryOptions) ModuleFactory {
        return ModuleFactory{
            .b = b,
            .tree_sitter_dep = opts.tree_sitter_dep,
            .tree_sitter_lib = opts.tree_sitter_lib,
            .optimize = opts.optimize,
            .target = opts.target,
            .test_step = opts.test_step,
        };
    }

    pub fn add(self: *ModuleFactory, name: []const u8, src_path: []const u8) *std.Build.Module {
        const mod = self.createModule(name, src_path);
        const test_runner = self.createTestForModule(mod, name);

        self.test_step.dependOn(&test_runner.step);

        const mod_test_step = self.b.step(name, self.b.fmt("Run {s} tests only", .{name}));
        mod_test_step.dependOn(&test_runner.step);

        return mod;
    }

    fn createTestForModule(self: *ModuleFactory, mod: *std.Build.Module, name: []const u8) *std.Build.Step.Run {
        const compile = self.b.addTest(.{
            .root_module = mod,
            .target = self.target,
            .optimize = .Debug,
            .filter = name,
        });
        return self.b.addRunArtifact(compile);
    }

    fn createModule(self: *ModuleFactory, name: []const u8, src_path: []const u8) *std.Build.Module {
        const mod = self.b.addModule(name, .{
            .root_source_file = self.b.path(src_path),
            .optimize = self.optimize,
            .target = self.target,
        });
        mod.addImport("tree-sitter", self.tree_sitter_dep.module("tree-sitter"));
        mod.linkLibrary(self.tree_sitter_lib);
        return mod;
    }
};
