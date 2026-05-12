const Token = @import("scanner.zig").Token;
const Scanner = @import("scanner.zig").Scanner;
const ScannerError = @import("scanner.zig").ScannerError;
const std = @import("std");

test "Scanner Tokenizes basic program" {
    const source = "var hello = 'hello world'; var e: Error = Err('This is an error');";
    var scanner: Scanner = Scanner.init(source);
    var token_buffer: [1024]Token = undefined;
    const token_count = try scanner.scan(&token_buffer);
    for (0..token_count) |i| {
        std.debug.print("Token: {s} Lexeme: {s}\n", .{ @tagName(token_buffer[i].token_type), token_buffer[i].lexeme });
    }
}

test "Scanner Emits Error For Invalid Program" {
    const invalid_source = "var hello = 'hello world'; var e: Error = Err('This is an err";
    var scanner: Scanner = Scanner.init(invalid_source);
    var token_buffer: [1024]Token = undefined;
    const token_count = scanner.scan(&token_buffer) catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return;
    };
    for (0..token_count) |i| {
        std.debug.print("Token: {s} Lexeme: {s}\n", .{ @tagName(token_buffer[i].token_type), token_buffer[i].lexeme });
    }
}
