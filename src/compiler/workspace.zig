const std = @import("std");
const AST = @import("ast.zig");
const helpers = @import("../cli/helpers.zig");
const options = @import("TAPE_lang_build_options");
const Parser = @import("parser.zig").Parser;
const TypeChecker = @import("type_checker.zig").TypeChecker;
const Diagnostics = @import("../helpers/diagnostics.zig").DiagnosticsReporter;

pub const WorkspaceError = std.mem.Allocator.Error || std.Io.OperateTimeoutError || error{
    CircularDependencyError,
    FileNotFoundError,
};

/// The possible state a module (file) can be in when being handled by the compiler
pub const ModuleState = enum { Parsing, Parsed, Hoisted, Checked };

/// A single file handled by the compiler
pub const Module = struct {
    filepath: []const u8,
    state: ModuleState,
    arena: std.heap.ArenaAllocator,
    ast: *AST.ASTNode,
    exports: std.StringHashMap(AST.TypeId),
    file_contents: []const u8,
    mutex: std.Io.Mutex,

    pub fn init(filepath: []const u8, file_contents: []const u8, allocator: std.mem.Allocator) !*Module {
        const module = try allocator.create(Module);
        module.* = Module{
            .filepath = filepath,
            .state = ModuleState.Parsing,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .ast = undefined,
            .exports = std.StringHashMap(AST.TypeId).init(allocator),
            .file_contents = file_contents,
            .mutex = std.Io.Mutex.init,
        };
        return module;
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Workspace {
        return Workspace{
            .allocator = allocator,
            .modules = std.StringHashMap(*Module).init(allocator),
            .modules_mutex = std.Io.Mutex.init,
            .io = io,
            .diagnostics = Diagnostics.init(allocator),
            .diagnostics_mutex = std.Io.Mutex.init,
        };
    }

    pub fn deinit(self: *Workspace) void {
        var modules_it = self.modules.valueIterator();
        while (modules_it.next()) |mod| {
            self.allocator.free(mod.*.file_contents);
            self.allocator.free(mod.*.filepath);
            mod.*.exports.deinit();
            mod.*.arena.deinit();
            self.allocator.destroy(mod.*);
        }

        self.modules.deinit();
        self.diagnostics.deinit();
    }

    /// Compiles the workspace starting from the entrypoint module.
    pub fn compile_workspace(self: *Workspace, entrypoint: []const u8) !void {
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

        const module = try Module.init(entrypoint_absolute, file_contents, self.allocator);
        errdefer {
            self.allocator.free(file_contents);
            self.allocator.free(entrypoint_absolute);
            self.allocator.destroy(module);
        }

        try self.modules_mutex.lock(self.io);
        try self.modules.put(entrypoint_absolute, module);
        self.modules_mutex.unlock(self.io);

        // Dispatch the entrypoint task to the Io group
        group.async(self.io, worker_parse_module, .{ParserWorkerParam{
            .workspace = self,
            .module = module,
            .group = &group,
            .io = self.io,
        }});

        // wait for tasks to complete
        try group.await(self.io);

        if (self.diagnostics.has_errors) {
            self.diagnostics.report_all(self.io) catch {};
        }
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

        if (self.modules.get(resolved_filepath) != null) {
            self.allocator.free(resolved_filepath);
            return;
        }

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

        const module = try Module.init(resolved_filepath, file_contents, self.allocator);
        try self.modules.put(resolved_filepath, module);

        group.async(self.io, worker_parse_module, .{ParserWorkerParam{
            .workspace = self,
            .module = module,
            .group = group,
            .io = self.io,
        }});
    }

    fn resolve_path(self: *Workspace, importer_filepath: []const u8, import_path: []const u8) ![]const u8 {
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
};
