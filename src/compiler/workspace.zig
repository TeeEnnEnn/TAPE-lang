const std = @import("std");
const AST = @import("ast.zig");
const helpers = @import("../cli/cli.zig");
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

fn runtime_panic_message(panic: Runtime.RuntimePanic) []const u8 {
    return switch (panic) {
        error.DivisionByZero => "Division by zero.",
        error.IndexOutOfBounds => "Collection index is out of bounds.",
        error.KeyNotFound => "Table key was not found.",
        error.ArgumentCountMismatch => "Function was called with the wrong number of arguments.",
        error.StackOverflow => "Runtime stack limit exceeded.",
        error.StackUnderflow, error.CorruptedState => "Internal VM state became invalid.",
        error.NegativeDenominator => "Invalid numeric operation.",
        error.OutOfMemory => "The runtime could not allocate memory.",
        error.InvalidValue => "Runtime value is invalid for this operation.",
        error.FinishedCoroutineResumption => "Cannot resume a finished coroutine.",
        error.CoroutineAlreadyRunning => "Cannot resume a coroutine that is already running.",
        error.Panic => "Program panicked.",
    };
}

fn runtime_panic_hint(panic: Runtime.RuntimePanic) ?[]const u8 {
    return switch (panic) {
        error.DivisionByZero => "Check the divisor before performing division.",
        error.IndexOutOfBounds => "Ensure the index is within the collection bounds.",
        error.KeyNotFound => "Ensure the key exists before indexing the table.",
        error.FinishedCoroutineResumption => "Create a new coroutine before resuming again.",
        error.CoroutineAlreadyRunning => "A coroutine may only be resumed by one execution path at a time.",
        error.StackOverflow => "Reduce recursion or increase the VM stack limit.",
        else => null,
    };
}

pub const WorkspaceError = std.mem.Allocator.Error || std.Io.OperateTimeoutError || error{
    CircularDependencyError,
    FileNotFoundError,
    CodeGenerationError,
};

pub const DebugOptions = struct {
    ast: bool = false,
    bytecode: bool = false,
    vm: bool = false,
    pipeline: bool = false,

    pub fn enable_all(self: *DebugOptions) void {
        self.* = .{ .ast = true, .bytecode = true, .vm = true, .pipeline = true };
    }
};

pub const CompileOptions = struct {
    execute: bool = false,
    debug: DebugOptions = .{},
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
    /// Declaration node of each exported name, so importers can copy the exporter's binding
    export_nodes: std.StringHashMap(*AST.ASTNode),
    file_contents: []const u8,
    mutex: std.Io.Mutex,
    dependencies: std.ArrayList(*Module),
    visit_state: ModuleVisitState = .NotVisited,
    function: *Entities.ObjectFunction,
    allocator: std.mem.Allocator,
    is_entrypoint: bool,

    pub fn init(filepath: []const u8, file_contents: []const u8, allocator: std.mem.Allocator, is_entrypoint: bool) !*Module {
        const module = try allocator.create(Module);
        module.* = Module{
            .filepath = filepath,
            .state = ModuleState.Parsing,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .ast = undefined,
            .binding_resolution = BindingResolution.init(allocator),
            .exports = std.StringHashMap(AST.TypeId).init(allocator),
            .export_nodes = std.StringHashMap(*AST.ASTNode).init(allocator),
            .file_contents = file_contents,
            .mutex = std.Io.Mutex.init,
            .dependencies = .empty,
            .function = undefined,
            .allocator = allocator,
            .is_entrypoint = is_entrypoint,
        };
        return module;
    }

    pub fn deinit(self: *Module) void {
        self.exports.deinit();
        self.export_nodes.deinit();
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

pub const WorkspaceGlobals = struct {
    next_function_constant_slot: u16 = 0,
    next_global_constant_slot: u16 = 0,
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
    /// values used between modules
    workspace_globals: WorkspaceGlobals,
    vm: ?*Runtime.VM,
    debug: DebugOptions,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Workspace {
        return Workspace{
            .allocator = allocator,
            .modules = std.StringHashMap(*Module).init(allocator),
            .modules_mutex = std.Io.Mutex.init,
            .io = io,
            .diagnostics = Diagnostics.init(allocator),
            .diagnostics_mutex = std.Io.Mutex.init,
            .vm = null,
            .workspace_globals = .{ .next_function_constant_slot = 0, .next_global_constant_slot = 0 },
            .debug = .{},
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

    /// Analyzes the workspace and, when requested, generates and executes it.
    /// Diagnostics are collected here and emitted by the CLI exactly once.
    pub fn compile_workspace(self: *Workspace, entrypoint: []const u8, compile_options: CompileOptions) !bool {
        self.debug = compile_options.debug;
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
                else => false,
            };
        };

        const entrypoint_module = try Module.init(entrypoint_absolute, file_contents, self.allocator, true);
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

        if (self.diagnostics.has_errors) return false;

        // detect cycles
        try entrypoint_module.detect_cycles();

        // sort modules
        const sorted_modules = try self.sort_modules(entrypoint_module);
        defer self.allocator.free(sorted_modules);

        if (compile_options.debug.ast) {
            for (sorted_modules) |module| print_node(module.ast, 0, 4);
        }

        // type check

        // all modules share the same type registry
        var type_registry = try TypeRegistry.init(self.allocator);
        defer type_registry.deinit();

        // type checking
        for (sorted_modules) |module| {
            if (compile_options.debug.pipeline) std.debug.print("Type checking {s}\n", .{module.filepath});
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

            if (self.diagnostics.has_errors) return false;
            if (compile_options.debug.pipeline) std.debug.print("Type checked {s}\n", .{module.filepath});
        }

        // resolve bindings
        if (compile_options.debug.pipeline) std.debug.print("Resolving bindings...\n", .{});
        for (sorted_modules) |module| {
            const new_resolution = BindingResolver.resolve(module.allocator, &type_registry, &self.diagnostics, module, self, module.ast) catch |err| {
                if (!self.diagnostics.has_errors) {
                    try self.diagnostics.add_diagnostic(.{
                        .column = 0,
                        .line = 0,
                        .stage = .BindingResolver,
                        .severity = .Error,
                        .message = "Binding resolution failed",
                        .hint = @errorName(err),
                        .file_path = module.filepath,
                    });
                }
                return false;
            };
            module.binding_resolution.deinit();
            module.binding_resolution = new_resolution;

            if (self.diagnostics.has_errors) return false;
            if (compile_options.debug.pipeline) std.debug.print("Resolved bindings for {s}\n", .{module.filepath});
        }

        if (!compile_options.execute) return true;

        // Code Generation is where the VM needs to be set up and the first isolate is created

        if (compile_options.debug.pipeline) std.debug.print("Generating code ...\n", .{});
        var vm = try Runtime.VM.init(.{ .debug_execution = compile_options.debug.vm }, self, self.allocator);
        self.vm = vm;
        // first isolate. Slots are unique program-wide, so size it from the
        // workspace totals after every module has been resolved.
        const first_isolate = try vm.new_isolate(self.workspace_globals.next_global_constant_slot, self.workspace_globals.next_function_constant_slot);
        first_isolate.gc.deactivate_collector();

        // emit Bytecode
        for (sorted_modules) |module| {
            var code_gen = try CodeGenerator.init(self.allocator, first_isolate, &module.binding_resolution, &type_registry, module.ast, &self.diagnostics, module);

            const function = code_gen.generate();
            if (function) |f| {
                module.function = f;
                if (compile_options.debug.bytecode) CodeGeneratorDebug.disassemble(&f.chunk, module.filepath);
            } else {
                if (!self.diagnostics.has_errors) {
                    try self.diagnostics.add_diagnostic(.{ .column = 0, .line = 0, .file_path = module.filepath, .message = "Code generation failed", .severity = .Error, .stage = .CodeGenerator });
                }
                return false;
            }
        }
        if (compile_options.debug.pipeline) std.debug.print("Code generated.\n", .{});
        // at this point all the modules should have bytecode in a ObjectFunction

        if (compile_options.debug.pipeline) std.debug.print("Creating script closure...\n", .{});
        const entrypoint_closure = try Entities.new_closure_object(first_isolate, entrypoint_module.function);
        first_isolate.isolate_closure = entrypoint_closure;

        first_isolate.gc.activate_collector();
        if (compile_options.debug.pipeline) std.debug.print("Executing...\n", .{});
        _ = first_isolate.execute() catch |err| {
            if (err != error.Panic) {
                first_isolate.print_stack_trace(null, err);
            }
            return false;
        };
        if (compile_options.debug.pipeline) std.debug.print("Execution completed.\n", .{});
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
            module = try Module.init(resolved_filepath, file_contents, self.allocator, false);
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

    /// Lexically normalizes a path, collapsing `.`, `..` and duplicate
    /// separators. Joined import paths accumulate `./` segments (the
    /// importer's dirname already ends in one), so without this the same
    /// file registers as two different modules and its types get
    /// duplicate ids.
    fn normalize_path(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const is_absolute = std.fs.path.isAbsolute(path);
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(allocator);
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
            if (std.mem.eql(u8, seg, "..")) {
                if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                    _ = parts.pop();
                    continue;
                }
                // Relative paths may escape; absolute paths clamp at root.
                if (!is_absolute) try parts.append(allocator, seg);
                continue;
            }
            try parts.append(allocator, seg);
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        if (is_absolute) try out.append(allocator, '/');
        for (parts.items, 0..) |part, i| {
            if (i > 0) try out.append(allocator, '/');
            try out.appendSlice(allocator, part);
        }
        if (out.items.len == 0) try out.appendSlice(allocator, ".");
        return out.toOwnedSlice(allocator);
    }

    pub fn resolve_path(self: *Workspace, importer_filepath: []const u8, import_path: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(import_path)) {
            const duped = try self.allocator.dupe(u8, import_path);
            defer self.allocator.free(duped);
            return try normalize_path(self.allocator, duped);
        }
        const dirname = std.fs.path.dirname(importer_filepath) orelse "";
        if (dirname.len == 0) {
            const duped = try self.allocator.dupe(u8, import_path);
            defer self.allocator.free(duped);
            return try normalize_path(self.allocator, duped);
        }
        const joined = try std.fs.path.join(self.allocator, &[_][]const u8{ dirname, import_path });
        defer self.allocator.free(joined);
        return try normalize_path(self.allocator, joined);
    }

    pub fn get_module(self: *Workspace, filepath: []const u8) !?*Module {
        try self.modules_mutex.lock(self.io);
        defer self.modules_mutex.unlock(self.io);
        return self.modules.get(filepath);
    }

    fn worker_parse_module(param: ParserWorkerParam) void {
        if (param.workspace.debug.pipeline) std.debug.print("Starting parsing {s}\n", .{param.module.filepath});

        var parser = Parser.init(param.module.arena.allocator(), param.workspace, param.module, param.io, param.group) catch |err| {
            param.workspace.diagnostics_mutex.lock(param.io) catch {};
            defer param.workspace.diagnostics_mutex.unlock(param.io);

            param.workspace.diagnostics.add_diagnostic(.{
                .column = 0,
                .line = 0,
                .stage = .Parser,
                .severity = .Error,
                .message = "Failed to create parser",
                .file_path = param.module.filepath,
                .hint = @errorName(err),
            }) catch {};

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

            if (!param.workspace.diagnostics.has_errors) {
                param.workspace.diagnostics.add_diagnostic(.{
                    .column = 0,
                    .line = 0,
                    .stage = .Parser,
                    .severity = .Error,
                    .message = "Failed to parse due to parser error.",
                    .file_path = param.module.filepath,
                }) catch {};
            }

            param.module.mutex.lock(param.io) catch {};
            param.module.state = .Parsed;
            param.module.mutex.unlock(param.io);
            return;
        };

        param.module.mutex.lock(param.io) catch {};
        param.module.ast = ast;
        param.module.state = .Parsed;
        param.module.mutex.unlock(param.io);

        if (param.workspace.debug.pipeline) std.debug.print("Finished parsing {s}\n", .{param.module.filepath});
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
