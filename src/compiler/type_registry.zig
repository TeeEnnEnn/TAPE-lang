const std = @import("std");
const ast = @import("ast.zig");

pub const TypeId = ast.TypeId;

pub const ShapeField = struct {
    name: []const u8,
    type: TypeId,
};

pub const TypeRegistryError = error{
    UnknownType,
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
    option: TypeId,
    result: struct { ok: TypeId, err: TypeId },
    _union: struct { left: TypeId, right: TypeId },
    shape: []ShapeField,
    identifier: struct { name: []const u8, generics: ?[]TypeId }, // errors, enums, structs
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
                if (function.return_type) |ret| {
                    const ret_id = try self.resolve(ret);
                    return try self.add_function_type(try arg_ids.toOwnedSlice(self.allocator), ret_id);
                }
                return try self.add_function_type(try arg_ids.toOwnedSlice(self.allocator), @intFromEnum(PrimitiveType.Nil));
            },
            .range_type => |range| {
                const start_id = try self.resolve(range.start);
                const end_id = try self.resolve(range.end);
                return try self.add_range_type(start_id, end_id);
            },
            .result_type => |result| {
                const ok_id = try self.resolve(result.ok_type);
                const err_id = try self.resolve(result.err_type);
                return try self.add_result_type(ok_id, err_id);
            },
            .option_type => |option| {
                const element_id = try self.resolve(option.element_type);
                return try self.add_option_type(element_id);
            },
            .identifier_type => |identifier| {
                const name = identifier.name.lexeme;
                const generics = identifier.generic_args;

                if (generics) |args| {
                    var resolved_generics: std.ArrayList(TypeId) = .empty;
                    for (args) |arg| {
                        const arg_id = try self.resolve(arg);
                        try resolved_generics.append(self.allocator, arg_id);
                    }
                    return try self.add_identifier_type(name, try resolved_generics.toOwnedSlice(self.allocator));
                }
                return try self.add_identifier_type(name, null);
            },
            .union_type => |union_node| {
                const left_id = try self.resolve(union_node.left);
                const right_id = try self.resolve(union_node.right);
                return try self.add_union_type(left_id, right_id);
            },
            .shape_type => |shape| {
                const fields = shape.fields;
                var field_types: std.ArrayList(ShapeField) = .empty;
                for (fields) |field| {
                    const name = field.name.lexeme;
                    const type_id = try self.resolve(field.type_annotation);
                    try field_types.append(self.allocator, .{ .name = name, .type = type_id });
                }
                return try self.add_shape_type(try field_types.toOwnedSlice(self.allocator));
            },
            .shape_expr => |shape| {
                const fields = shape.fields;
                var field_types: std.ArrayList(ShapeField) = .empty;
                for (fields) |field| {
                    const name = field.name.lexeme;
                    const type_id = try self.resolve(field.type_annotation);
                    try field_types.append(self.allocator, .{ .name = name, .type = type_id });
                }
                return try self.add_shape_type(try field_types.toOwnedSlice(self.allocator));
            },
            else => return TypeRegistryError.UnknownType,
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

    pub fn add_function_type(self: *TypeRegistry, args: []TypeId, ret: TypeId) !TypeId {
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

    pub fn add_result_type(self: *TypeRegistry, ok_type: TypeId, err_type: TypeId) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .result => |r| {
                    if (r.ok == ok_type and r.err == err_type) {
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ .result = .{ .ok = ok_type, .err = err_type } });
        return id;
    }

    pub fn add_option_type(self: *TypeRegistry, some_type: TypeId) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .option => |existing_some_type| {
                    if (existing_some_type == some_type) {
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ .option = some_type });
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

    pub fn add_shape_type(self: *TypeRegistry, fields: []ShapeField) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .shape => |existing_fields| {
                    if (existing_fields.len != fields.len) continue;

                    var match = true;
                    for (existing_fields, 0..) |ef, i| {
                        if (!std.mem.eql(u8, ef.name, fields[i].name) or ef.type != fields[i].type) {
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
        try self.types.append(self.allocator, .{ .shape = fields });
        return id;
    }

    pub fn get_type_info(self: *TypeRegistry, id: TypeId) TypeInfo {
        return self.types.items[id];
    }
};
