const std = @import("std");
const ast = @import("ast.zig");

pub const TypeId = ast.TypeId;

pub const StructField = struct {
    name: []const u8,
    type: TypeId,
    is_static: bool,
    is_pub: bool,
    has_default: bool,
};

pub const StructMethod = struct {
    name: []const u8,
    type: TypeId,
    is_static: bool,
    is_pub: bool,
};

pub const TypeRegistryError = error{
    UnknownType,
    TypeResolutionConflict,
} || std.mem.Allocator.Error;

pub const PrimitiveType = enum(TypeId) {
    Nil = 0,
    Int,
    Float,
    String,
    Bool,
    Never,
};

pub const TypeInfo = union(enum) {
    primitive: PrimitiveType,
    array: TypeId,
    tuple: []TypeId,
    range: struct { start: TypeId, end: TypeId },
    table: struct { key: TypeId, value: TypeId },
    function: struct { args: []TypeId, ret: TypeId },
    coroutine: struct { args: []TypeId, ret: TypeId, yield: TypeId },
    _union: struct { left: TypeId, right: TypeId },
    _error: struct { name: []const u8, variants: [][]const u8, source_file: []const u8 },
    _enum: struct { name: []const u8, variants: [][]const u8, source_file: []const u8 },
    _struct: struct { name: []const u8, fields: []StructField, methods: []StructMethod, source_file: []const u8 },
    _type: struct { name: []const u8, resolved_type: TypeId, source_file: []const u8 },
    identifier: struct { name: []const u8, source_file: []const u8, generics: ?[]TypeId }, // errors, enums, structs
};

pub const TypeRegistry = struct {
    types: std.ArrayList(TypeInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !TypeRegistry {
        var registry = TypeRegistry{
            .types = .empty,
            .allocator = allocator,
        };

        try registry.types.append(allocator, .{ .primitive = .Nil });
        try registry.types.append(allocator, .{ .primitive = .Int });
        try registry.types.append(allocator, .{ .primitive = .Float });
        try registry.types.append(allocator, .{ .primitive = .String });
        try registry.types.append(allocator, .{ .primitive = .Bool });
        try registry.types.append(allocator, .{ .primitive = .Never });

        return registry;
    }

    pub fn deinit(self: *TypeRegistry) void {
        self.types.deinit(self.allocator);
    }

    /// Resolves a type node to a type ID.
    ///
    /// Returns the type ID of the resolved type, or an error if the type could not be resolved.
    ///
    /// # Errors
    /// - `UnknownType`: The type could not be resolved.
    /// - `TypeResolutionConflict`: The type could not be resolved due to a type resolution conflict.
    /// - `Allocator.Error`: The type could not be resolved due to an allocator error.
    pub fn resolve(self: *TypeRegistry, type_node: *ast.ASTNode) TypeRegistryError!TypeId {
        return switch (type_node.*) {
            .nil_type => @intFromEnum(PrimitiveType.Nil),
            .int_type => @intFromEnum(PrimitiveType.Int),
            .float_type => @intFromEnum(PrimitiveType.Float),
            .string_type => @intFromEnum(PrimitiveType.String),
            .bool_type => @intFromEnum(PrimitiveType.Bool),
            .never_type => @intFromEnum(PrimitiveType.Never),

            .array_type => |array| {
                const element_id = try self.resolve(array.element_type);
                return try self.add_array_type(element_id);
            },
            .table_type => |table| {
                const key_id = try self.resolve(table.key_type);
                const value_id = try self.resolve(table.element_type);
                return try self.add_table_type(key_id, value_id);
            },
            .tuple_type => |tuple| {
                const elements = tuple.element_types;
                var element_ids: std.ArrayList(TypeId) = .empty;
                for (elements) |element| {
                    const element_id = try self.resolve(element);
                    try element_ids.append(self.allocator, element_id);
                }
                return try self.add_tuple_type(try element_ids.toOwnedSlice(self.allocator));
            },
            .fn_type => |function| {
                const args = function.params;
                var arg_ids: std.ArrayList(TypeId) = .empty;
                for (args) |arg| {
                    const arg_id = try self.resolve(arg);
                    try arg_ids.append(self.allocator, arg_id);
                }
                const ret_id = try self.resolve(function.return_type);
                return try self.add_function_type(try arg_ids.toOwnedSlice(self.allocator), ret_id);
            },
            .co_type => |co| {
                const args = co.params;
                var arg_ids: std.ArrayList(TypeId) = .empty;
                for (args) |arg| {
                    const arg_id = try self.resolve(arg);
                    try arg_ids.append(self.allocator, arg_id);
                }
                const ret_id = try self.resolve(co.return_type);
                const yield_id = try self.resolve(co.yield_type);
                return try self.add_coroutine_type(try arg_ids.toOwnedSlice(self.allocator), ret_id, yield_id);
            },
            .range_type => |range| {
                const start_id = try self.resolve(range.start);
                const end_id = try self.resolve(range.end);
                return try self.add_range_type(start_id, end_id);
            },

            .identifier_type => |identifier| {
                const name = identifier.name.lexeme;
                const source_file = identifier.source_file;

                const existing_type = self.get_named_type(name, source_file);
                if (existing_type) |id| {
                    return id;
                }
                return TypeRegistryError.UnknownType;
            },
            .union_type => |union_node| {
                const left_id = try self.resolve(union_node.left);
                const right_id = try self.resolve(union_node.right);
                return try self.add_union_type(left_id, right_id);
            },
            else => {
                return TypeRegistryError.UnknownType;
            },
        };
    }

    pub fn add_array_type(self: *TypeRegistry, element_type: TypeId) !TypeId {
        // check for existing type
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .array => |existing_element| {
                    if (existing_element == element_type) {
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ .array = element_type });
        return id;
    }

    pub fn add_table_type(self: *TypeRegistry, key_type: TypeId, value_type: TypeId) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .table => |t| {
                    if (t.key == key_type and t.value == value_type) {
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ .table = .{ .key = key_type, .value = value_type } });
        return id;
    }

    pub fn add_tuple_type(self: *TypeRegistry, elements: []TypeId) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .tuple => |existing_elements| {
                    if (std.mem.eql(TypeId, existing_elements, elements)) {
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ .tuple = elements });
        return id;
    }

    /// Adds a function type to the registry.
    ///
    /// # Errors
    /// `std.mem.Allocator.Error` if the function type could not be added.
    pub fn add_function_type(self: *TypeRegistry, args: []TypeId, ret: TypeId) std.mem.Allocator.Error!TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .function => |f| {
                    if (std.mem.eql(TypeId, f.args, args) and f.ret == ret) {
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ .function = .{ .args = args, .ret = ret } });
        return id;
    }

    pub fn add_coroutine_type(self: *TypeRegistry, args: []TypeId, ret: TypeId, yield: TypeId) std.mem.Allocator.Error!TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .coroutine => |c| {
                    if (std.mem.eql(TypeId, c.args, args) and c.ret == ret and c.yield == yield) {
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ .coroutine = .{ .args = args, .ret = ret, .yield = yield } });
        return id;
    }

    pub fn add_range_type(self: *TypeRegistry, start: TypeId, end: TypeId) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .range => |r| {
                    if (r.start == start and r.end == end) {
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ .range = .{ .start = start, .end = end } });
        return id;
    }

    pub fn add_identifier_type(self: *TypeRegistry, name: []const u8, generics: ?[]TypeId) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .identifier => |id_info| {
                    if (std.mem.eql(u8, id_info.name, name)) {
                        const generics_match = if (id_info.generics) |eql_gen|
                            (if (generics) |gen| std.mem.eql(TypeId, eql_gen, gen) else false)
                        else
                            (generics == null);
                        if (generics_match) {
                            return @as(TypeId, @intCast(index));
                        }
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ .identifier = .{ .name = name, .generics = generics } });
        return id;
    }

    pub fn add_union_type(self: *TypeRegistry, left_id: TypeId, right_id: TypeId) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                ._union => |u| {
                    if (u.left == left_id and u.right == right_id) {
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ ._union = .{ .left = left_id, .right = right_id } });
        return id;
    }

    pub fn add_type_type(self: *TypeRegistry, name: []const u8, resolved_type: TypeId, source_file: []const u8) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                ._type => |existing_type| {
                    if (!std.mem.eql(u8, existing_type.name, name) or !std.mem.eql(u8, existing_type.source_file, source_file)) continue;
                    if (existing_type.resolved_type != resolved_type) {
                        return TypeRegistryError.TypeResolutionConflict; // names are the same but the resolved types differ
                    }
                    return @as(TypeId, @intCast(index));
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ ._type = .{ .name = name, .resolved_type = resolved_type, .source_file = source_file } });
        return id;
    }

    pub fn add_struct_type(self: *TypeRegistry, name: []const u8, fields: []StructField, methods: []StructMethod, source_file: []const u8) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                ._struct => |existing_struct| {
                    if (!std.mem.eql(u8, existing_struct.name, name) or !std.mem.eql(u8, existing_struct.source_file, source_file)) continue;
                    if (existing_struct.fields.len != fields.len or existing_struct.methods.len != methods.len) {
                        return TypeRegistryError.TypeResolutionConflict; // names are the same but the number of fields or methods differ
                    }

                    var match = true;
                    for (existing_struct.fields, 0..) |ef, i| {
                        if (!std.mem.eql(u8, ef.name, fields[i].name) or ef.type != fields[i].type) {
                            match = false;
                            break;
                        }
                    }
                    for (existing_struct.methods, 0..) |em, i| {
                        if (!std.mem.eql(u8, em.name, methods[i].name) or em.type != methods[i].type) {
                            match = false;
                            break;
                        }
                    }
                    if (match) return @as(TypeId, @intCast(index));
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ ._struct = .{ .name = name, .fields = fields, .methods = methods, .source_file = source_file } });
        return id;
    }

    pub fn add_error_type(self: *TypeRegistry, name: []const u8, variants: [][]const u8, source_file: []const u8) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                ._error => |existing_error| {
                    if (!std.mem.eql(u8, existing_error.name, name) or !std.mem.eql(u8, existing_error.source_file, source_file)) continue;
                    if (existing_error.variants.len != variants.len) {
                        return TypeRegistryError.TypeResolutionConflict; // names are the same but the number of variants differ
                    }

                    var match = true;
                    for (existing_error.variants, 0..) |ev, i| {
                        if (!std.mem.eql(u8, ev, variants[i])) {
                            match = false;
                            break;
                        }
                    }
                    if (match) return @as(TypeId, @intCast(index));
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ ._error = .{ .name = name, .variants = variants, .source_file = source_file } });
        return id;
    }

    pub fn add_enum_type(self: *TypeRegistry, name: []const u8, variants: [][]const u8, source_file: []const u8) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                ._enum => |existing_enum| {
                    if (!std.mem.eql(u8, existing_enum.name, name) or !std.mem.eql(u8, existing_enum.source_file, source_file)) continue;
                    if (existing_enum.variants.len != variants.len) {
                        return TypeRegistryError.TypeResolutionConflict; // names are the same but the number of variants differ
                    }

                    var match = true;
                    for (existing_enum.variants, 0..) |ev, i| {
                        if (!std.mem.eql(u8, ev, variants[i])) {
                            match = false;
                            break;
                        }
                    }
                    if (match) return @as(TypeId, @intCast(index));
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ ._enum = .{ .name = name, .variants = variants, .source_file = source_file } });
        return id;
    }

    pub fn get_type_info(self: *TypeRegistry, id: TypeId) TypeInfo {
        return self.types.items[id];
    }

    pub fn get_named_type(self: *TypeRegistry, name: []const u8, source_file: []const u8) ?TypeId {
        // First try exact match with source_file (local types take precedence)
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                ._enum => |enum_info| {
                    if (!std.mem.eql(u8, enum_info.name, name)) continue;
                    if (!std.mem.eql(u8, enum_info.source_file, source_file)) continue;
                    return @as(TypeId, @intCast(index));
                },
                ._struct => |struct_info| {
                    if (!std.mem.eql(u8, struct_info.name, name)) continue;
                    if (!std.mem.eql(u8, struct_info.source_file, source_file)) continue;
                    return @as(TypeId, @intCast(index));
                },
                ._type => |type_info| {
                    if (!std.mem.eql(u8, type_info.name, name)) continue;
                    if (!std.mem.eql(u8, type_info.source_file, source_file)) continue;
                    return @as(TypeId, @intCast(index));
                },
                ._error => |error_info| {
                    if (!std.mem.eql(u8, error_info.name, name)) continue;
                    if (!std.mem.eql(u8, error_info.source_file, source_file)) continue;
                    return @as(TypeId, @intCast(index));
                },
                else => continue,
            }
        }
        // Fallback: match by name only (handles types imported via use_decl)
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                ._enum => |enum_info| {
                    if (!std.mem.eql(u8, enum_info.name, name)) continue;
                    return @as(TypeId, @intCast(index));
                },
                ._struct => |struct_info| {
                    if (!std.mem.eql(u8, struct_info.name, name)) continue;
                    return @as(TypeId, @intCast(index));
                },
                ._type => |type_info| {
                    if (!std.mem.eql(u8, type_info.name, name)) continue;
                    return @as(TypeId, @intCast(index));
                },
                ._error => |error_info| {
                    if (!std.mem.eql(u8, error_info.name, name)) continue;
                    return @as(TypeId, @intCast(index));
                },
                else => continue,
            }
        }
        return null;
    }
};
