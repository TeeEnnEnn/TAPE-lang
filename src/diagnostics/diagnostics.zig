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
        const stderr = std.Io.File.stderr();
        var buf: [32]u8 = undefined;
        for (self.diagnostics.items) |diagnostic| {
            try stderr.writeStreamingAll(io, "\n");
            const color = switch (diagnostic.severity) {
                .Fatal => BOLD_RED,
                .Error => RED,
                .Warning => YELLOW,
                .Info => GRAY,
            };
            try stderr.writeStreamingAll(io, color);
            try stderr.writeStreamingAll(io, @tagName(diagnostic.severity));
            try stderr.writeStreamingAll(io, RESET);
            try stderr.writeStreamingAll(io, " during ");
            try stderr.writeStreamingAll(io, @tagName(diagnostic.stage));
            try stderr.writeStreamingAll(io, "\nAt ");
            try stderr.writeStreamingAll(io, diagnostic.file_path);
            try stderr.writeStreamingAll(io, " (line ");
            try stderr.writeStreamingAll(io, std.fmt.bufPrint(&buf, "{}", .{diagnostic.line}) catch unreachable);
            try stderr.writeStreamingAll(io, ", column ");
            try stderr.writeStreamingAll(io, std.fmt.bufPrint(&buf, "{}", .{diagnostic.column}) catch unreachable);
            try stderr.writeStreamingAll(io, ")\n");
            try stderr.writeStreamingAll(io, diagnostic.message);
            try stderr.writeStreamingAll(io, "\n");
            if (diagnostic.hint) |hint| {
                try stderr.writeStreamingAll(io, "Hint: ");
                try stderr.writeStreamingAll(io, hint);
                try stderr.writeStreamingAll(io, "\n");
            }
        }
        self.diagnostics.clearAndFree(self.allocator);
        self.has_errors = false;
        self.has_warnings = false;
        self.has_infos = false;
        try stderr.writeStreamingAll(io, RESET);
    }

    pub fn has_content(self: *DiagnosticsReporter) bool {
        return self.has_errors or self.has_warnings or self.has_infos;
    }
};
