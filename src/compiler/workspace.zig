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

/// The possible state a file can be in when being handled by the compiler
pub const ModuleState = enum { Queued, Parsing, Parsed, Hoisted, Checked };

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
            .state = ModuleState.Queued,
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
    io: std.Io,
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(*Module),
    /// mutex for accessing modules hash map
    modules_mutex: std.Io.Mutex,
    io: std.Io,
    diagnostics: Diagnostics,
    /// Mutex for accessing diagnostics
    diagnostics_mutex: std.Io.Mutex,
    threads: std.ArrayList(std.Thread) = .empty,
    threads_mutex: std.Io.Mutex,
    thread_semaphore: std.Io.Semaphore,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Workspace {
        return Workspace{
            .allocator = allocator,
            .modules = std.StringHashMap(*Module).init(allocator),
            .modules_mutex = std.Io.Mutex.init,
            .io = io,
            .diagnostics = Diagnostics.init(allocator),
            .diagnostics_mutex = std.Io.Mutex.init,
            .thread_semaphore = .{ .permits = options.compiler_thread_count },
            .threads_mutex = std.Io.Mutex.init,
        };
    }

    pub fn deinit(self: *Workspace) void {
        var modules_it = self.modules.valueIterator();
        while (modules_it.next()) |mod| {
            self.allocator.free(mod.*.file_contents);
            mod.*.exports.deinit();
            mod.*.arena.deinit();
        }

        self.modules.deinit();
        self.diagnostics.deinit();
        self.threads.deinit(self.allocator);
    }

    /// Compiles the workspace starting from the entrypoint module.
    pub fn compile_workspace(self: *Workspace, entrypoint: []const u8) !void {
        // start the compilation of the entrypoint module
        self.parse_module(entrypoint) catch {
            try self.diagnostics_mutex.lock(self.io);
            self.diagnostics.add_diagnostic(.{ .column = 0, .line = 0, .stage = .Parser, .severity = .Error, .message = "Failed to parse entrypoint module", .file_path = entrypoint }) catch {};
            self.diagnostics_mutex.unlock(self.io);
        };

        // let all modules parse (do work)

        var work_done = false;
        start_work: while (!work_done) {
            try self.modules_mutex.lock(self.io); // read the modules hash map
            defer self.modules_mutex.unlock(self.io);
            var mod_it = self.modules.valueIterator();
            while (mod_it.next()) |mod| {
                try mod.*.mutex.lock(self.io); // read the module state
                const state = mod.*.state;
                if (state == .Queued) {
                    mod.*.state = .Parsing;
                }
                mod.*.mutex.unlock(self.io);

                switch (state) {
                    .Queued => {
                        try self.thread_semaphore.wait(self.io);
                        const thread = try std.Thread.spawn(.{ .allocator = self.allocator }, worker_parse_module, .{ParserWorkerParam{
                            .workspace = self,
                            .module = mod.*,
                            .io = self.io,
                        }});
                        try self.threads.append(self.allocator, thread);
                    },
                    else => {},
                }
            }

            var check_it = self.modules.valueIterator();
            while (check_it.next()) |mod| {
                try mod.*.mutex.lock(self.io);
                defer mod.*.mutex.unlock(self.io);
                if (mod.*.state != ModuleState.Parsed) {
                    // if any module is still not parsed, then keep working
                    continue :start_work;
                }
            }
            work_done = true;
        }

        // join all threads at the end
        for (self.threads.items) |thread| {
            thread.join();
        }

        if (self.diagnostics.has_errors) {
            self.diagnostics.report_all(self.io) catch {};
        }
    }

    /// Adds a module to the workspace and parses it.
    pub fn parse_module(self: *Workspace, filepath: []const u8) (WorkspaceError || std.mem.Allocator.Error)!void {
        // try to load the file from disk
        const file_contents = helpers.read_file(filepath, std.Io.Dir.cwd(), self.io, self.allocator) catch |e| {
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => WorkspaceError.FileNotFoundError,
            };
        };

        try self.modules_mutex.lock(self.io);
        if (self.modules.get(filepath)) |_| {
            self.modules_mutex.unlock(self.io);
            return;
        }
        const module = try Module.init(filepath, file_contents, self.allocator);
        try self.modules.put(filepath, module);
        self.modules_mutex.unlock(self.io);
    }

    pub fn get_module(self: *Workspace, filepath: []const u8) !?*Module {
        try self.modules_mutex.lock(self.io);
        defer self.modules_mutex.unlock(self.io);
        return self.modules.get(filepath);
    }

    fn worker_parse_module(param: ParserWorkerParam) !void {
        std.debug.print("Starting Parsing {s}\n", .{param.module.filepath});
        var parser = Parser.init(param.module.arena.allocator(), param.workspace, param.module, param.io) catch {
            param.workspace.diagnostics.add_diagnostic(.{ .column = 0, .line = 0, .stage = .Parser, .severity = .Error, .message = "Failed to create parser", .file_path = param.module.filepath }) catch {
                try param.module.mutex.lock(param.io);
                param.module.state = ModuleState.Parsed;
                param.module.mutex.unlock(param.io);
                param.workspace.thread_semaphore.post(param.io);
                return;
            };
            try param.module.mutex.lock(param.io);
            param.module.state = ModuleState.Parsed;
            param.module.mutex.unlock(param.io);
            param.workspace.thread_semaphore.post(param.io);
            return;
        };
        try param.module.mutex.lock(param.io);
        param.module.state = ModuleState.Parsing;
        param.module.mutex.unlock(param.io);

        const ast = parser.parse() catch {
            param.workspace.diagnostics.add_diagnostic(.{ .column = 0, .line = 0, .stage = .Parser, .severity = .Error, .message = "Failed to parse due to parser error.", .file_path = param.module.filepath }) catch {};
            try param.module.mutex.lock(param.io);
            param.module.state = ModuleState.Parsed;
            param.workspace.thread_semaphore.post(param.io);
            param.module.mutex.unlock(param.io);
            return;
        };
        try param.module.mutex.lock(param.io);
        param.module.ast = ast;
        param.module.state = ModuleState.Parsed;
        param.workspace.thread_semaphore.post(param.io);
        param.module.mutex.unlock(param.io);

        std.debug.print("Finished Parsing {s}\n", .{param.module.filepath});
    }
};
