const scanner = @import("../../compiler/scanner.zig");
const Token = scanner.Token;
const TokenType = scanner.TokenType;
const Scanner = scanner.Scanner;
const ScannerError = scanner.ScannerError;
const std = @import("std");

fn checkTokens(source: []const u8, expected_types: []const TokenType) !void {
    var s = Scanner.init(source);
    var token_buffer: [1024]Token = undefined;
    const token_count = try s.scan(&token_buffer);

    // Subtract 1 from token_count because the last one is always EOF
    if (token_count - 1 != expected_types.len) {
        std.debug.print("\nExpected {d} tokens, got {d}\n", .{ expected_types.len, token_count - 1 });
        for (0..token_count) |i| {
            std.debug.print("{d}: {s} '{s}'\n", .{ i, @tagName(token_buffer[i].token_type), token_buffer[i].lexeme });
        }
        return error.TokenCountMismatch;
    }

    for (expected_types, 0..) |expected_type, i| {
        if (token_buffer[i].token_type != expected_type) {
            std.debug.print("\nAt index {d}: Expected {s}, got {s} ('{s}')\n", .{ i, @tagName(expected_type), @tagName(token_buffer[i].token_type), token_buffer[i].lexeme });
            return error.TokenTypeMismatch;
        }
    }
}

test "Scanner Tokenizes basic program" {
    const allocator = std.testing.allocator;
    _ = allocator;
    const source = "var hello = 'hello world'; var e = 42;";
    var s: Scanner = Scanner.init(source);

    var token_buffer: [1024]Token = undefined;
    const token_count = try s.scan(&token_buffer);
    try std.testing.expect(token_count > 0);
}

test "Scanner Emits Error For Unterminated String" {
    const invalid_source = "var hello = \"unterminated string";
    const allocator = std.testing.allocator;
    _ = allocator;
    var s: Scanner = Scanner.init(invalid_source);
    var token_buffer: [1024]Token = undefined;
    try std.testing.expectError(ScannerError.UnterminatedString, s.scan(&token_buffer));
}

test "Scanner Keywords" {
    const allocator = std.testing.allocator;
    _ = allocator;
    const source = "native resume and as break co const continue catch default else false for fn from give if in match new nil not or orelse panic pub return struct true type use var while try yield with";
    const expected = [_]TokenType{
        .NATIVE, .RESUME, .AND, .AS, .BREAK, .CO, .CONST, .CONTINUE, .CATCH, .DEFAULT, .ELSE, .FALSE, .FOR, .FN, .FROM, .GIVE, .IF, .IN, .MATCH, .NEW, .NIL, .NOT, .OR, .ORELSE, .PANIC, .PUB, .RETURN, .STRUCT, .TRUE, .TYPE, .USE, .VAR, .WHILE, .TRY, .YIELD, .WITH,
    };
    try checkTokens(source, &expected);
}

test "Scanner Type Keywords" {
    const allocator = std.testing.allocator;
    _ = allocator;
    const source = "Nil Bool Int Float String Array Table Range Never";
    const expected = [_]TokenType{
        .NIL_TYPE, .BOOL_TYPE, .INT_TYPE, .FLOAT_TYPE, .STRING_TYPE, .ARRAY_TYPE, .TABLE_TYPE, .RANGE_TYPE, .NEVER_TYPE,
    };
    try checkTokens(source, &expected);
}

test "Scanner Operators and Punctuation" {
    const source = "( ) { } [ ] , . .. - + ; / * ** % : -> != = == => > >= < <= << >> & ^ | ~ += -= *= /= %= ++ ++= **= ? !";
    const expected = [_]TokenType{ .LEFT_PAREN, .RIGHT_PAREN, .LEFT_BRACE, .RIGHT_BRACE, .LEFT_SQUARE, .RIGHT_SQUARE, .COMMA, .DOT, .DOT_DOT, .MINUS, .PLUS, .SEMICOLON, .SLASH, .STAR, .STAR_STAR, .PERCENT, .COLON, .ARROW, .NOT_EQUAL, .EQUAL, .EQUAL_EQUAL, .EQUAL_ARROW, .GREATER, .GREATER_EQUAL, .LESS, .LESS_EQUAL, .LEFT_SHIFT, .RIGHT_SHIFT, .AMPERSAND, .CARET, .PIPE, .TILDE, .PLUS_EQUAL, .MINUS_EQUAL, .STAR_EQUAL, .SLASH_EQUAL, .PERCENT_EQUAL, .PLUS_PLUS, .PLUS_PLUS_EQUAL, .STAR_STAR_EQUAL, .QUESTION, .BANG };
    try checkTokens(source, &expected);
}

test "Scanner Star Operators" {
    const source = "* ** *= **=";
    const expected = [_]TokenType{ .STAR, .STAR_STAR, .STAR_EQUAL, .STAR_STAR_EQUAL };
    try checkTokens(source, &expected);
}

test "Scanner Numbers" {
    const source = "123 123.456 0b1010 0xABC";
    const expected = [_]TokenType{
        .INT, .FLOAT, .BINARY_INT, .HEX_INT,
    };
    try checkTokens(source, &expected);
}

test "Scanner Identifiers" {
    const source = "foo _bar baz123";
    const expected = [_]TokenType{
        .IDENTIFIER, .IDENTIFIER, .IDENTIFIER,
    };
    try checkTokens(source, &expected);
}

test "Scanner Comments and Whitespace" {
    const source =
        \\// This is a comment
        \\var x = 1; // Another comment
        \\var y = 2;
    ;
    const expected = [_]TokenType{
        .VAR, .IDENTIFIER, .EQUAL, .INT, .SEMICOLON,
        .VAR, .IDENTIFIER, .EQUAL, .INT, .SEMICOLON,
    };
    try checkTokens(source, &expected);
}
