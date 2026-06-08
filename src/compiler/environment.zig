const std = @import("std");
const TypeId = @import("ast.zig").TypeId;
const DiagnosticReporter = @import("../helpers/diagnostics.zig").DiagnosticsReporter;

pub const EnvironmentError = error{
    DuplicateDefinition,
    UndefinedSymbol,
} || std.mem.Allocator.Error;

pub const Environment = struct {
    allocator: std.mem.Allocator,
    symbols: std.StringHashMap(TypeId),
    parent: ?*Environment,
    diagnostics: *DiagnosticReporter,
    file_path: []const u8,

    /// Initializes a new environment with the given allocator and parent environment.
    pub fn init(allocator: std.mem.Allocator, parent: ?*Environment, diagnostics: *DiagnosticReporter, file_path: []const u8) Environment {
        return .{
            .parent = parent,
            .allocator = allocator,
            .symbols = std.StringHashMap(TypeId).init(allocator),
            .diagnostics = diagnostics,
            .file_path = file_path,
        };
    }

    /// Deinitializes the environment and frees its resources.
    pub fn deinit(self: *Environment) void {
        self.symbols.deinit();
    }

    /// Defines a symbol in the current scope. Returns error if already defined in *this* scope.
    pub fn define(self: *Environment, name: []const u8, id: TypeId) EnvironmentError!void {
        if (self.symbols.contains(name)) {
            try self.diagnostics.add_diagnostic(.{ .file_path = self.file_path, .column = 0, .line = 0, .stage = .TypeChecker, .severity = .Error, .message = "Duplicate definition", .hint = "Symbol is already defined." });
            return EnvironmentError.DuplicateDefinition;
        }
        try self.symbols.put(name, id);
    }

    /// Looks up a symbol in the current scope and its parent scopes.
    /// Returns the symbol's type ID if found, or an error if not found.
    pub fn lookup(self: *Environment, name: []const u8) EnvironmentError!TypeId {
        var curr: ?*Environment = self;
        while (curr) |env| {
            if (env.symbols.get(name)) |id| {
                return id;
            }
            curr = env.parent;
        }
        try self.diagnostics.add_diagnostic(.{ .file_path = self.file_path, .column = 0, .line = 0, .stage = .TypeChecker, .severity = .Error, .message = "Undefined symbol", .hint = "Symbol is not defined." });
        return EnvironmentError.UndefinedSymbol;
    }

    /// Returns true if the symbol is defined in the current scope.
    /// Does not check parent scopes.
    pub fn contains(self: *Environment, name: []const u8) bool {
        return self.symbols.contains(name);
    }
};
