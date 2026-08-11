const std = @import("std");
const AST = @import("ast.zig");
const TypeId = AST.TypeId;
const DeclRef = AST.DeclRef;
const DiagnosticReporter = @import("../diagnostics/diagnostics.zig").DiagnosticsReporter;

pub const EnvironmentError = error{
    DuplicateDefinition,
    UndefinedSymbol,
} || std.mem.Allocator.Error;

pub const SymbolInfo = struct {
    type_id: TypeId,
    decl: ?DeclRef = null,
    is_const: bool,
};

pub const Environment = struct {
    allocator: std.mem.Allocator,
    symbols: std.StringHashMap(SymbolInfo),
    parent: ?*Environment,

    /// Initializes a new environment with the given allocator and parent environment.
    pub fn init(allocator: std.mem.Allocator, parent: ?*Environment) Environment {
        return .{
            .parent = parent,
            .allocator = allocator,
            .symbols = std.StringHashMap(SymbolInfo).init(allocator),
        };
    }

    /// Deinitializes the environment and frees its resources.
    pub fn deinit(self: *Environment) void {
        self.symbols.deinit();
    }

    /// Defines a symbol with no declaration identity. Use for types, struct/enum/error
    /// names, and anything that isn't a runtime value the codegen resolver needs to place.
    pub fn define(self: *Environment, name: []const u8, id: TypeId) EnvironmentError!void {
        return self.define_binding(name, id, null, false);
    }

    /// Defines a symbol with declaration identity attached, for the codegen resolver to use.
    pub fn define_binding(self: *Environment, name: []const u8, id: TypeId, decl: ?DeclRef, is_const: bool) EnvironmentError!void {
        if (self.symbols.contains(name)) {
            return EnvironmentError.DuplicateDefinition;
        }
        try self.symbols.put(name, .{ .type_id = id, .decl = decl, .is_const = is_const });
    }

    /// Looks up a symbol's type ID only. Existing call sites keep working unchanged.
    pub fn lookup(self: *Environment, name: []const u8) EnvironmentError!TypeId {
        const info = try self.lookup_binding(name);
        return info.type_id;
    }

    /// Looks up a symbol's full info, including declaration identity if present.
    pub fn lookup_binding(self: *Environment, name: []const u8) EnvironmentError!SymbolInfo {
        return (try self.lookup_binding_scope(name)).info;
    }

    /// Looks up a symbol's full info and the scope in which it was actually found.
    pub fn lookup_binding_scope(self: *Environment, name: []const u8) EnvironmentError!struct {
        info: SymbolInfo,
        scope: *Environment,
    } {
        var curr: ?*Environment = self;
        while (curr) |env| {
            if (env.symbols.get(name)) |info| {
                return .{ .info = info, .scope = env };
            }
            curr = env.parent;
        }
        return EnvironmentError.UndefinedSymbol;
    }

    /// Returns true if the symbol is defined in the current scope.
    /// Does not check parent scopes.
    pub fn contains(self: *Environment, name: []const u8) bool {
        return self.symbols.contains(name);
    }
};
