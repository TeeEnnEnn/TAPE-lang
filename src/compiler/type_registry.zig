const std = @import("std");
const AST = @import("ast.zig");

pub const TypeId = AST.TypeId;

fn optional_type_ids_equal(a: ?TypeId, b: ?TypeId) bool {
    if (a) |a_id| return if (b) |b_id| a_id == b_id else false;
    return b == null;
}

pub const StructField = struct {
    name: []const u8,
    type: TypeId,
    is_pub: bool,
    default_value: ?*AST.ASTNode,
};

pub const StructMethod = struct {
    name: []const u8,
    type: TypeId,
    is_pub: bool,
    method_node: *AST.ASTNode,
};

pub const EnumVariant = struct {
    name: []const u8,
    type: ?TypeId,
};

pub const TypeRegistryError = error{
    UnknownType,
    TypeResolutionConflict,
    NestedOptional,
    OptionalOfNil,
    /// In the error position of a union type, a non error type was given
    NonErrorUnionError,
    /// Error unions cannot be nested as the success type (`E1!(E2!T)`)
    NestedErrorUnion,
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
    native_function: struct { args: []TypeId, ret: TypeId },
    coroutine: struct { args: []TypeId, ret: TypeId, yield: TypeId, resume_with: TypeId },
    optional: struct { inner: TypeId },
    /// null err typeId allows any error type
    error_union: struct { err: ?TypeId, ok: TypeId },
    _error: struct { name: []const u8, variants: [][]const u8, source_file: []const u8 },
    _enum: struct { name: []const u8, variants: []EnumVariant, source_file: []const u8, has_payloads: bool },
    _struct: struct { name: []const u8, fields: []StructField, methods: []StructMethod, source_file: []const u8 },
    _type: struct { name: []const u8, resolved_type: TypeId, source_file: []const u8 },
    native_type: struct { name: []const u8, source_file: []const u8 },
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
        // Free the heap-allocated slices owned by each type entry. Name and
        // source_file slices point into the module's arena and are not freed.
        for (self.types.items) |info| {
            switch (info) {
                .tuple => |elements| self.allocator.free(elements),
                .function => |f| self.allocator.free(f.args),
                .coroutine => |c| self.allocator.free(c.args),
                .identifier => |id_info| {
                    if (id_info.generics) |generics| self.allocator.free(generics);
                },
                ._struct => |s| {
                    self.allocator.free(s.fields);
                    self.allocator.free(s.methods);
                },
                ._error => |e| self.allocator.free(e.variants),
                ._enum => |e| self.allocator.free(e.variants),
                else => {},
            }
        }
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
    pub fn resolve(self: *TypeRegistry, type_node: *AST.ASTNode) TypeRegistryError!TypeId {
        return switch (type_node.*) {
            .nil_type => @backingInt(PrimitiveType.Nil),
            .int_type => @backingInt(PrimitiveType.Int),
            .float_type => @backingInt(PrimitiveType.Float),
            .string_type => @backingInt(PrimitiveType.String),
            .bool_type => @backingInt(PrimitiveType.Bool),
            .never_type => @backingInt(PrimitiveType.Never),

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
            .anon_struct_decl => |decl| {
                var fields: std.ArrayList(StructField) = .empty;
                for (decl.fields) |field| {
                    try fields.append(self.allocator, .{
                        .name = field.name.lexeme,
                        .type = try self.resolve(field.type_annotation),
                        .is_pub = true,
                        .default_value = field.default_value,
                    });
                }
                const empty_methods = try self.allocator.alloc(StructMethod, 0);
                return try self.add_struct_type("<anonymous>", try fields.toOwnedSlice(self.allocator), empty_methods, "");
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
                const resume_with_id = try self.resolve(co.resume_with_type);
                return try self.add_coroutine_type(try arg_ids.toOwnedSlice(self.allocator), yield_id, resume_with_id, ret_id);
            },
            .range_type => |range| {
                const start_id = try self.resolve(range.start);
                const end_id = try self.resolve(range.end);
                return try self.add_range_type(start_id, end_id);
            },
            .optional_type => |optional| {
                const inner_id = try self.resolve(optional.inner);
                return try self.add_optional_type(inner_id);
            },
            .error_union_type => |error_union| {
                const err_id: ?TypeId = if (error_union.err) |err| try self.resolve(err) else null;
                const ok_id = try self.resolve(error_union.ok);
                return try self.add_error_union_type(err_id, ok_id);
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
            else => {
                return TypeRegistryError.UnknownType;
            },
        };
    }

    /// Returns the inner type of an optional, or null if `id` is not optional.
    pub fn unwrap_optional(self: *TypeRegistry, id: TypeId) ?TypeId {
        return switch (self.get_type_info(id)) {
            .optional => |o| o.inner,
            else => null,
        };
    }

    pub fn add_error_union_type(self: *TypeRegistry, err_type: ?TypeId, ok_type: TypeId) !TypeId {
        if (err_type) |e| {
            const error_type_info = self.get_type_info(e);
            if (error_type_info != ._error) {
                return TypeRegistryError.NonErrorUnionError;
            }
        }
        // disallow nesting of error unions in the success part of the union
        if (self.get_type_info(ok_type) == .error_union) {
            return TypeRegistryError.NestedErrorUnion;
        }

        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .error_union => |existing| {
                    if (existing.err == err_type and existing.ok == ok_type) {
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ .error_union = .{ .err = err_type, .ok = ok_type } });
        return id;
    }

    pub fn add_optional_type(self: *TypeRegistry, inner_type: TypeId) !TypeId {
        // an optional of nil is not allowed
        if (inner_type == @backingInt(PrimitiveType.Nil)) {
            return TypeRegistryError.OptionalOfNil;
        }
        // a nested optional is not allowed
        if (self.get_type_info(inner_type) == .optional) {
            return TypeRegistryError.NestedOptional;
        }

        // check for existing type
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .optional => |existing| {
                    if (existing.inner == inner_type) {
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ .optional = .{ .inner = inner_type } });
        return id;
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
                        self.allocator.free(elements);
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
                        self.allocator.free(args);
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

    pub fn add_native_function_type(self: *TypeRegistry, args: []TypeId, ret: TypeId) std.mem.Allocator.Error!TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .native_function => |f| {
                    if (std.mem.eql(TypeId, f.args, args) and f.ret == ret) {
                        self.allocator.free(args);
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ .native_function = .{ .args = args, .ret = ret } });
        return id;
    }

    pub fn add_coroutine_type(self: *TypeRegistry, args: []TypeId, yield: TypeId, resume_with: TypeId, ret: TypeId) std.mem.Allocator.Error!TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .coroutine => |c| {
                    if (std.mem.eql(TypeId, c.args, args) and c.yield == yield and c.resume_with == resume_with and c.ret == ret) {
                        self.allocator.free(args);
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ .coroutine = .{ .args = args, .yield = yield, .resume_with = resume_with, .ret = ret } });
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
                            if (generics) |gen| self.allocator.free(gen);
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

    pub fn add_native_type_type(self: *TypeRegistry, name: []const u8, source_file: []const u8) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                .native_type => |existing_type| {
                    if (!std.mem.eql(u8, existing_type.name, name) or !std.mem.eql(u8, existing_type.source_file, source_file)) continue;
                    return @as(TypeId, @intCast(index));
                },
                else => continue,
            }
        }

        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ .native_type = .{ .name = name, .source_file = source_file } });
        return id;
    }

    pub fn add_type_type(self: *TypeRegistry, name: []const u8, resolved_type: TypeId, source_file: []const u8) !TypeId {
        for (self.types.items) |info| {
            switch (info) {
                ._type => |existing_type| {
                    if (!std.mem.eql(u8, existing_type.name, name) or !std.mem.eql(u8, existing_type.source_file, source_file)) continue;
                    if (existing_type.resolved_type != resolved_type) {
                        return TypeRegistryError.TypeResolutionConflict; // names are the same but the resolved types differ
                    }
                    return resolved_type;
                },
                else => continue,
            }
        }

        // add new type
        try self.types.append(self.allocator, .{ ._type = .{ .name = name, .resolved_type = resolved_type, .source_file = source_file } });
        return resolved_type;
    }

    pub fn add_struct_type(self: *TypeRegistry, name: []const u8, fields: []StructField, methods: []StructMethod, source_file: []const u8) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                ._struct => |existing_struct| {
                    if (!std.mem.eql(u8, existing_struct.name, name) or !std.mem.eql(u8, existing_struct.source_file, source_file)) continue;
                    if (existing_struct.fields.len != fields.len or existing_struct.methods.len != methods.len) {
                        if (std.mem.eql(u8, name, "<anonymous>")) continue;
                        self.allocator.free(fields);
                        self.allocator.free(methods);
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
                    if (match) {
                        self.allocator.free(fields);
                        self.allocator.free(methods);
                        return @as(TypeId, @intCast(index));
                    }
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
                        self.allocator.free(variants);
                        return TypeRegistryError.TypeResolutionConflict; // names are the same but the number of variants differ
                    }

                    var match = true;
                    for (existing_error.variants, 0..) |ev, i| {
                        if (!std.mem.eql(u8, ev, variants[i])) {
                            match = false;
                            break;
                        }
                    }
                    if (match) {
                        self.allocator.free(variants);
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ ._error = .{ .name = name, .variants = variants, .source_file = source_file } });
        return id;
    }

    pub fn add_enum_type(self: *TypeRegistry, name: []const u8, variants: []EnumVariant, source_file: []const u8, has_payloads: bool) !TypeId {
        for (self.types.items, 0..) |info, index| {
            switch (info) {
                ._enum => |existing_enum| {
                    if (!std.mem.eql(u8, existing_enum.name, name) or !std.mem.eql(u8, existing_enum.source_file, source_file) or existing_enum.has_payloads != has_payloads) continue;
                    if (existing_enum.variants.len != variants.len) {
                        self.allocator.free(variants);
                        return TypeRegistryError.TypeResolutionConflict; // names are the same but the number of variants differ
                    }

                    var match = true;
                    for (existing_enum.variants, 0..) |ev, i| {
                        if (!std.mem.eql(u8, ev.name, variants[i].name) or !optional_type_ids_equal(ev.type, variants[i].type)) {
                            match = false;
                            break;
                        }
                    }
                    if (match) {
                        self.allocator.free(variants);
                        return @as(TypeId, @intCast(index));
                    }
                },
                else => continue,
            }
        }

        // add new type
        const id = @as(TypeId, @intCast(self.types.items.len));
        try self.types.append(self.allocator, .{ ._enum = .{ .name = name, .variants = variants, .source_file = source_file, .has_payloads = has_payloads } });
        return id;
    }

    pub fn set_enum_variants(self: *TypeRegistry, id: TypeId, variants: []EnumVariant, has_payloads: bool) !void {
        const entry = &self.types.items[id];
        if (entry.* != ._enum) return TypeRegistryError.TypeResolutionConflict;
        self.allocator.free(entry._enum.variants);
        entry._enum.variants = variants;
        entry._enum.has_payloads = has_payloads;
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
                    return @as(TypeId, type_info.resolved_type);
                },
                ._error => |error_info| {
                    if (!std.mem.eql(u8, error_info.name, name)) continue;
                    if (!std.mem.eql(u8, error_info.source_file, source_file)) continue;
                    return @as(TypeId, @intCast(index));
                },
                .native_type => |native_type_info| {
                    if (!std.mem.eql(u8, native_type_info.name, name)) continue;
                    if (!std.mem.eql(u8, native_type_info.source_file, source_file)) continue;
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
                    return @as(TypeId, type_info.resolved_type);
                },
                ._error => |error_info| {
                    if (!std.mem.eql(u8, error_info.name, name)) continue;
                    return @as(TypeId, @intCast(index));
                },
                .native_type => |native_type_info| {
                    if (!std.mem.eql(u8, native_type_info.name, name)) continue;
                    return @as(TypeId, @intCast(index));
                },
                else => continue,
            }
        }
        return null;
    }
};
