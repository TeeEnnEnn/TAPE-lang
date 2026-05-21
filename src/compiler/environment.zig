const std = @import("std");
const TypeId = @import("ast.zig").TypeId;

pub const EnvironmentError = error{
    DuplicateDefinition,
    UndefinedName,
} || std.mem.Allocator.Error;

pub const Environment = struct {
    allocator: std.mem.Allocator,
    symbols: std.StringHashMap(TypeId),
    parent: ?*Environment,

    pub fn init(allocator: std.mem.Allocator, parent: ?*Environment) Environment {
        return .{
            .parent = parent,
            .allocator = allocator,
            .symbols = std.StringHashMap(TypeId).init(allocator),
        };
    }

    pub fn deinit(self: *Environment) void {
        self.symbols.deinit();
    }

    /// Defines a symbol in the current scope. Returns error if already defined in *this* scope.
    pub fn define(self: *Environment, name: []const u8, id: TypeId) EnvironmentError!void {
        if (self.symbols.contains(name)) {
            return EnvironmentError.DuplicateDefinition;
        }
        try self.symbols.put(name, id);
    }

    pub fn lookup(self: *Environment, name: []const u8) EnvironmentError!TypeId {
        var curr: ?*Environment = self;
        while (curr) |env| {
            if (env.symbols.get(name)) |id| {
                return id;
            }
            curr = env.parent;
        }
        return EnvironmentError.UndefinedName;
    }
};
