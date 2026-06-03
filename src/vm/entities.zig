//! Entity Representation for TAPE
//! Entities are Values and Objects.

pub const ObjectType = enum {};

pub const ObjectHeader = struct {};

const Value = union(enum) { int: i64, float: f64, boolean: bool, nil: void, object: *ObjectHeader };
