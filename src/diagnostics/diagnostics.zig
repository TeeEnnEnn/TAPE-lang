//! Diagnostics utilities for the TAPE compiler.
const std = @import("std");
const CLI = @import("../cli/cli.zig");
const BOLD_RED = CLI.BOLD_RED;
const RED = CLI.RED;
const YELLOW = CLI.YELLOW;
const GRAY = CLI.GRAY;
const RESET = CLI.RESET;

pub const Severity = enum {
    Fatal,
    Error,
    Warning,
    Info,
};

pub const Stage = enum {
    Scanner,
    Parser,
    TypeChecker,
    BindingResolver,
    CodeGenerator,
    Execution,
};

pub const Diagnostic = struct {
    /// The stage at which the diagnostic was generated.
    stage: Stage,
    /// The severity of the diagnostic.
    severity: Severity,
    /// The diagnostic message.
    message: []const u8,
    /// The path to the file where the diagnostic was generated.
    file_path: []const u8,
    /// The line number where the diagnostic was generated.
    line: usize,
    /// The column number where the diagnostic was generated.
    column: usize,
    /// The hint to the user to fix the diagnostic.
    hint: ?[]const u8 = null,
};

pub const DiagnosticsReporter = struct {
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayList(Diagnostic),
    has_errors: bool,
    has_warnings: bool,
    has_infos: bool,

    pub fn init(allocator: std.mem.Allocator) DiagnosticsReporter {
        return .{
            .allocator = allocator,
            .diagnostics = .empty,
            .has_errors = false,
            .has_warnings = false,
            .has_infos = false,
        };
    }

    pub fn deinit(self: *DiagnosticsReporter) void {
        self.diagnostics.deinit(self.allocator);
    }

    pub fn add_diagnostic(self: *DiagnosticsReporter, diagnostic: Diagnostic) !void {
        switch (diagnostic.severity) {
            .Error, .Fatal => self.has_errors = true,
            .Warning => self.has_warnings = true,
            .Info => self.has_infos = true,
        }

        try self.diagnostics.append(self.allocator, diagnostic);
    }

    pub fn report_all(self: *DiagnosticsReporter, io: std.Io) !void {
        _ = io;
        for (self.diagnostics.items) |diagnostic| {
            const color = switch (diagnostic.severity) {
                .Fatal => BOLD_RED,
                .Error => RED,
                .Warning => YELLOW,
                .Info => GRAY,
            };
            std.debug.print("\n{s}{s}{s} during {s}\nAt {s} (line {}, column {})\n{s}\n", .{
                color,
                @tagName(diagnostic.severity),
                RESET,
                @tagName(diagnostic.stage),
                diagnostic.file_path,
                diagnostic.line,
                diagnostic.column,
                diagnostic.message,
            });
            if (diagnostic.hint) |hint| {
                std.debug.print("Hint: {s}\n", .{hint});
            }
        }
        self.diagnostics.clearAndFree(self.allocator);
        self.has_errors = false;
        self.has_warnings = false;
        self.has_infos = false;
    }

    pub fn has_content(self: *DiagnosticsReporter) bool {
        return self.has_errors or self.has_warnings or self.has_infos;
    }
};
