//! Diagnostics utilities for the TAPE compiler.

const std = @import("std");

const Severity = enum {
    Error,
    Warning,
    Info,
};

const Stage = enum {
    Scanner,
    Parser,
    TypeChecker,
    CodeGenerator,
    Execution,
};

const Diagnostic = struct {
    message: []const u8,
    line: u32,
    column: u32,
    file: []const u8,
    severity: Severity,
    stage: Stage,
};

const DiagnosticsReporter = struct {
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayList(Diagnostic),

    pub fn init(allocator: std.mem.Allocator) DiagnosticsReporter {
        return .{
            .allocator = allocator,
            .diagnostics = .empty,
        };
    }

    pub fn deinit(self: *DiagnosticsReporter) void {
        self.diagnostics.deinit(self.allocator);
    }

    pub fn add_diagnostic(self: *DiagnosticsReporter, diagnostic: Diagnostic) void {
        self.diagnostics.append(diagnostic) catch {};
    }

    pub fn report(self: *DiagnosticsReporter) void {
        for (self.diagnostics.items) |diagnostic| {
            switch (diagnostic.severity) {
                .Error => |severity| {
                    _ = severity;
                },
                .Warning => |severity| {
                    _ = severity;
                },
                .Info => |severity| {
                    _ = severity;
                },
            }
        }
    }
};
