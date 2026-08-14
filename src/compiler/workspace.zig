const std = @import("std");
const AST = @import("ast.zig");
const helpers = @import("../cli/cli.zig");
const options = @import("TAPE_lang_build_options");
const Parser = @import("parser.zig").Parser;
const TypeChecker = @import("type_checker.zig").TypeChecker;
const TypeRegistry = @import("type_registry.zig").TypeRegistry;
const Diagnostics = @import("../diagnostics/diagnostics.zig").DiagnosticsReporter;
const Environment = @import("environment.zig").Environment;
const BindingResolver = @import("../compiler/binding_resolver.zig").BindingResolver;
const BindingResolution = @import("../compiler/binding_resolver.zig").BindingResolution;
const Entities = @import("../runtime/entities.zig");
const CodeGenerator = @import("code_gen.zig").CodeGenerator;
const Runtime = @import("../runtime/vm.zig");
const print_node = @import("ast_debug.zig").print_node;
const CodeGeneratorDebug = @import("code_gen_debug.zig").ChunkDisassembler;

pub const WorkspaceError = std.mem.Allocator.Error || std.Io.OperateTimeoutError || error{
    CircularDependencyError,
    FileNotFoundError,
    CodeGenerationError,
};

/// The possible state a module (file) can be in when being handled by the compiler
pub const ModuleState = enum { Parsing, Parsed, Hoisted, Checked };

pub const ModuleVisitState = enum {
    NotVisited,
    Visiting,
    Visited,
};

/// A single file handled by the compiler
pub const Module = struct {
    filepath: []const u8,
    state: ModuleState,
    arena: std.heap.ArenaAllocator,
    ast: *AST.ASTNode,
    binding_resolution: BindingResolution,
    exports: std.StringHashMap(AST.TypeId),
    file_contents: []const u8,
    mutex: std.Io.Mutex,
    dependencies: std.ArrayList(*Module),
    visit_state: ModuleVisitState = .NotVisited,
    function: *Entities.ObjectFunction,
    allocator: std.mem.Allocator,

    pub fn init(filepath: []const u8, file_contents: []const u8, allocator: std.mem.Allocator) !*Module {
        const module = try allocator.create(Module);
        module.* = Module{
            .filepath = filepath,
            .state = ModuleState.Parsing,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .ast = undefined,
            .binding_resolution = BindingResolution.init(allocator),
            .exports = std.StringHashMap(AST.TypeId).init(allocator),
            .file_contents = file_contents,
            .mutex = std.Io.Mutex.init,
            .dependencies = .empty,
            .function = undefined,
            .allocator = allocator,
        };
        return module;
    }

    pub fn deinit(self: *Module) void {
        self.exports.deinit();
        self.dependencies.deinit(self.allocator);
        self.binding_resolution.deinit();
        self.arena.deinit();
    }

    fn detect_cycles(self: *Module) !void {
        if (self.visit_state == .Visited) return;
        if (self.visit_state == .Visiting) {
            return WorkspaceError.CircularDependencyError;
        }
        self.visit_state = .Visiting;
        for (self.dependencies.items) |dep| {
            try dep.detect_cycles();
        }
        self.visit_state = .Visited;
    }
};

const ParserWorkerParam = struct {
    workspace: *Workspace,
    module: *Module,
    group: *std.Io.Group,
    io: std.Io,
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(*Module),
    /// Mutex for accessing the modules hash map
    modules_mutex: std.Io.Mutex,
    io: std.Io,
    diagnostics: Diagnostics,
    /// Mutex for accessing diagnostics
    diagnostics_mutex: std.Io.Mutex,
    vm: ?*Runtime.VM,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Workspace {
        return Workspace{
            .allocator = allocator,
            .modules = std.StringHashMap(*Module).init(allocator),
            .modules_mutex = std.Io.Mutex.init,
            .io = io,
            .diagnostics = Diagnostics.init(allocator),
            .diagnostics_mutex = std.Io.Mutex.init,
            .vm = null,
        };
    }

    pub fn deinit(self: *Workspace) void {
        if (self.vm) |vm| {
            vm.deinit();
            self.allocator.destroy(vm);
        }

        var modules_it = self.modules.valueIterator();
        while (modules_it.next()) |mod| {
            self.allocator.free(mod.*.file_contents);
            self.allocator.free(mod.*.filepath);
            mod.*.deinit();
            self.allocator.destroy(mod.*);
        }

        self.modules.deinit();
        self.diagnostics.deinit();
    }

    /// Compiles the workspace starting from the entrypoint module.
    /// Returns whether the compilation completed without reporting errors.
    pub fn compile_workspace(self: *Workspace, entrypoint: []const u8) !bool {
        var group = std.Io.Group.init;

        const entrypoint_absolute = try self.allocator.dupe(u8, entrypoint);
        errdefer self.allocator.free(entrypoint_absolute);

        const file_contents = helpers.read_file(entrypoint_absolute, std.Io.Dir.cwd(), self.io, self.allocator) catch |e| {
            self.allocator.free(entrypoint_absolute);
            try self.diagnostics_mutex.lock(self.io);
            defer self.diagnostics_mutex.unlock(self.io);
            try self.diagnostics.add_diagnostic(.{
                .column = 0,
                .line = 0,
                .stage = .Parser,
                .severity = .Error,
                .message = "Failed to read entrypoint module file",
                .file_path = entrypoint,
            });
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => WorkspaceError.FileNotFoundError,
            };
        };

        const entrypoint_module = try Module.init(entrypoint_absolute, file_contents, self.allocator);
        errdefer {
            self.allocator.free(file_contents);
            self.allocator.free(entrypoint_absolute);
            self.allocator.destroy(entrypoint_module);
        }

        try self.modules_mutex.lock(self.io);
        try self.modules.put(entrypoint_absolute, entrypoint_module);
        self.modules_mutex.unlock(self.io);

        // Dispatch the entrypoint task to the Io group
        group.async(self.io, worker_parse_module, .{ParserWorkerParam{
            .workspace = self,
            .module = entrypoint_module,
            .group = &group,
            .io = self.io,
        }});

        // wait for tasks to complete
        try group.await(self.io);

        if (self.diagnostics.has_errors) {
            self.diagnostics.report_all(self.io) catch {};
            return false;
        }

        // detect cycles
        try entrypoint_module.detect_cycles();

        // sort modules
        const sorted_modules = try self.sort_modules(entrypoint_module);

        for (sorted_modules) |module| {
            print_node(module.ast, 0, 4);
        }

        // type check

        // all modules share the same type registry
        var type_registry = try TypeRegistry.init(self.allocator);
        defer type_registry.deinit();

        for (sorted_modules) |module| {
            std.debug.print("Type checking {s}\n", .{module.filepath});
            // each module has its own environment and type checker
            var global_environment = Environment.init(self.allocator, null);
            defer global_environment.deinit();
            var type_checker = TypeChecker.init(self.allocator, &type_registry, &global_environment, &self.diagnostics, module, self);
            _ = type_checker.check(module.ast) catch |err| {
                if (!self.diagnostics.has_errors) {
                    // The type checker failed without reporting a diagnostic.
                    // Surface the error so compilation stops before code generation.
                    try self.diagnostics.add_diagnostic(.{
                        .column = 0,
                        .line = 0,
                        .stage = .TypeChecker,
                        .severity = .Error,
                        .message = "Type checking failed",
                        .hint = @errorName(err),
                        .file_path = module.filepath,
                    });
                }
            };

            if (self.diagnostics.has_content()) {
                const had_errors = self.diagnostics.has_errors;
                self.diagnostics.report_all(self.io) catch {};
                if (had_errors) {
                    return false;
                }
            }
            std.debug.print("Type checked {s}\n", .{module.filepath});
        }
        // resolve bindings
        std.debug.print("Resolving bindings...\n", .{});
        for (sorted_modules) |module| {
            const new_resolution = BindingResolver.resolve(module.allocator, &type_registry, &self.diagnostics, module, self, module.ast) catch {
                if (self.diagnostics.has_content()) {
                    const had_errors = self.diagnostics.has_errors;
                    self.diagnostics.report_all(self.io) catch {};
                    if (had_errors) return false;
                }
                return false;
            };
            module.binding_resolution.deinit();
            module.binding_resolution = new_resolution;

            if (self.diagnostics.has_content()) {
                const had_errors = self.diagnostics.has_errors;
                self.diagnostics.report_all(self.io) catch {};
                if (had_errors) {
                    return false;
                }
            }
            std.debug.print("Type checked {s}\n", .{module.filepath});
        }

        // Code Generation is where the VM needs to be set up and the first isolate is created

        std.debug.print("Generating code ...\n", .{});
        // empty config for defaults
        var vm = try Runtime.VM.init(.{}, self, self.allocator);
        self.vm = vm;
        // first isolate
        const first_isolate = try vm.new_isolate();

        // emit Bytecode
        for (sorted_modules) |module| {
            var code_gen = try CodeGenerator.init(self.allocator, first_isolate, &module.binding_resolution, &type_registry, module.ast, &self.diagnostics, module);

            const function = code_gen.generate();
            if (function) |f| {
                module.function = f;
                CodeGeneratorDebug.disassemble(&f.chunk, module.filepath);
            } else {
                try self.diagnostics.add_diagnostic(.{ .column = 0, .line = 0, .file_path = module.filepath, .message = "Code generation failed", .severity = .Error, .stage = .CodeGenerator });
                return WorkspaceError.CodeGenerationError;
            }
            //
        }
        std.debug.print("Code Generated ...\n", .{});
        // at this point all the modules should have bytecode in a ObjectFunction

        std.debug.print("Creating Script Closure...\n", .{});
        const entrypoint_closure = try Entities.new_closure_object(first_isolate, entrypoint_module.function);
        first_isolate.isolate_closure = entrypoint_closure;

        std.debug.print("Executing...\n", .{});

        const result = try first_isolate.execute();
        _ = result;
        std.debug.print("\x1b[32m Done. \x1b[0m\n", .{});
        return true;
    }

    /// submits an imported file to the group for parsing
    /// called by a parser when it encounters an import ('use')
    pub fn submit_import(
        self: *Workspace,
        group: *std.Io.Group,
        importer_filepath: []const u8,
        import_path: []const u8,
    ) !void {
        const resolved_filepath = try self.resolve_path(importer_filepath, import_path);
        errdefer self.allocator.free(resolved_filepath);

        try self.modules_mutex.lock(self.io);
        defer self.modules_mutex.unlock(self.io);

        var module: *Module = undefined;
        var is_new = false;

        if (self.modules.get(resolved_filepath)) |existing_module| {
            module = existing_module;
            self.allocator.free(resolved_filepath);
        } else {
            const file_contents = helpers.read_file(resolved_filepath, std.Io.Dir.cwd(), self.io, self.allocator) catch {
                self.allocator.free(resolved_filepath);
                try self.diagnostics_mutex.lock(self.io);
                defer self.diagnostics_mutex.unlock(self.io);
                try self.diagnostics.add_diagnostic(.{
                    .column = 0,
                    .line = 0,
                    .stage = .Parser,
                    .severity = .Error,
                    .message = "Imported file not found",
                    .file_path = importer_filepath,
                });
                return;
            };

            module = try Module.init(resolved_filepath, file_contents, self.allocator);
            try self.modules.put(resolved_filepath, module);
            is_new = true;
            // resolved_filepath is now owned by the module and modules HashMap
        }

        if (self.modules.get(importer_filepath)) |importer_module| {
            importer_module.dependencies.append(self.allocator, module) catch {};
        }

        if (is_new) {
            group.async(self.io, worker_parse_module, .{ParserWorkerParam{
                .workspace = self,
                .module = module,
                .group = group,
                .io = self.io,
            }});
        }
    }

    pub fn resolve_path(self: *Workspace, importer_filepath: []const u8, import_path: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(import_path)) {
            return try self.allocator.dupe(u8, import_path);
        }
        const dirname = std.fs.path.dirname(importer_filepath) orelse "";
        if (dirname.len == 0) {
            return try self.allocator.dupe(u8, import_path);
        }
        return try std.fs.path.join(self.allocator, &[_][]const u8{ dirname, import_path });
    }

    pub fn get_module(self: *Workspace, filepath: []const u8) !?*Module {
        try self.modules_mutex.lock(self.io);
        defer self.modules_mutex.unlock(self.io);
        return self.modules.get(filepath);
    }

    fn worker_parse_module(param: ParserWorkerParam) void {
        std.debug.print("Starting Parsing {s}\n", .{param.module.filepath});

        var parser = Parser.init(param.module.arena.allocator(), param.workspace, param.module, param.io, param.group) catch {
            param.workspace.diagnostics_mutex.lock(param.io) catch {};
            defer param.workspace.diagnostics_mutex.unlock(param.io);

            param.workspace.diagnostics.add_diagnostic(.{ .column = 0, .line = 0, .stage = .Parser, .severity = .Error, .message = "Failed to create parser", .file_path = param.module.filepath }) catch {};

            param.module.mutex.lock(param.io) catch {};
            param.module.state = .Parsed;
            param.module.mutex.unlock(param.io);
            return;
        };

        param.module.mutex.lock(param.io) catch {};
        param.module.state = .Parsing;
        param.module.mutex.unlock(param.io);

        const ast = parser.parse() catch {
            param.workspace.diagnostics_mutex.lock(param.io) catch {};
            defer param.workspace.diagnostics_mutex.unlock(param.io);

            param.workspace.diagnostics.add_diagnostic(.{ .column = 0, .line = 0, .stage = .Parser, .severity = .Error, .message = "Failed to parse due to parser error.", .file_path = param.module.filepath }) catch {};

            param.module.mutex.lock(param.io) catch {};
            param.module.state = .Parsed;
            param.module.mutex.unlock(param.io);
            return;
        };

        param.module.mutex.lock(param.io) catch {};
        param.module.ast = ast;
        param.module.state = .Parsed;
        param.module.mutex.unlock(param.io);

        std.debug.print("Finished Parsing {s}\n", .{param.module.filepath});
    }

    fn sort_modules(self: *Workspace, entrypoint_module: *Module) ![]*Module {
        var modules_it = self.modules.valueIterator();
        while (modules_it.next()) |module| {
            module.*.visit_state = .NotVisited;
        }
        var list: std.ArrayList(*Module) = .empty;
        errdefer list.deinit(self.allocator);

        try self.sort_visit(entrypoint_module, &list);
        return list.toOwnedSlice(self.allocator);
    }

    fn sort_visit(self: *Workspace, module: *Module, list: *std.ArrayList(*Module)) !void {
        if (module.visit_state == .Visited) return;

        for (module.dependencies.items) |dep| {
            try self.sort_visit(dep, list);
        }
        module.visit_state = .Visited;
        try list.append(self.allocator, module);
    }
};
