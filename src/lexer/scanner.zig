const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;

pub const TokenType = enum {
    // Single-character tokens
    LEFT_PAREN,
    RIGHT_PAREN,
    LEFT_BRACE,
    RIGHT_BRACE,
    LEFT_SQUARE,
    RIGHT_SQUARE,
    DOLLAR_LEFT_SQUARE,
    COMMA,
    DOT,
    DOT_DOT,
    MINUS,
    PLUS,
    SEMICOLON,
    SLASH,
    BACKSLASH,
    STAR,
    STAR_STAR,
    PERCENT,
    COLON,
    // One or two character tokens
    ARROW,
    BANG_EQUAL,
    EQUAL,
    EQUAL_EQUAL,
    EQUAL_ARROW,
    GREATER,
    GREATER_EQUAL,
    LESS,
    LESS_EQUAL,
    LEFT_SHIFT,
    RIGHT_SHIFT,
    AMPERSAND,
    CARET,
    PIPE,
    TILDE,
    PLUS_EQUAL,
    MINUS_EQUAL,
    STAR_EQUAL,
    SLASH_EQUAL,
    BACK_SLASH_EQUAL,
    PERCENT_EQUAL,
    QUESTION_MARK,
    COLON_COLON,
    // Literals
    IDENTIFIER,
    STRING,
    INT,
    FLOAT,
    BINARY_INT,
    HEX_INT,
    // Keywords
    AND,
    NOT,
    ELSE,
    FALSE,
    FOR,
    FN,
    IF,
    IN,
    NIL,
    OR,
    RETURN,
    TRUE,
    VAR,
    WHILE,
    BREAK,
    CONTINUE,
    USE,
    FROM,
    PUB,
    AS,
    MATCH,
    OK,
    ERR,
    NONE,
    SOME,
    DEFAULT,
    GIVE,
    TYPEOF,
    NEW,
    PANIC,
    STRUCT,
    SHAPE,
    IMPL,
    TYPE,
    NATIVE,
    STATIC,
    // Type keywords
    NIL_TYPE,
    BOOL_TYPE,
    INT_TYPE,
    FLOAT_TYPE,
    STRING_TYPE,
    ARRAY_TYPE,
    TABLE_TYPE,
    ERROR_TYPE,
    RESULT_TYPE,
    RANDOM_TYPE,
    FILE_TYPE,
    VECTOR_TYPE,
    COMPLEX_TYPE,
    MATRIX_TYPE,
    TUPLE_TYPE,
    BUFFER_TYPE,
    RANGE_TYPE,
    NEVER_TYPE,
    ITERATOR_TYPE,
    OPTION_TYPE,
    ANY_TYPE,
    // Special
    EOF,
};

pub const Token = struct {
    token_type: TokenType,
    lexeme: []const u8,
    line: usize,
};

pub const ScannerError = error{
    UnterminatedString,
    UnexpectedCharacter,
    UnexpectedToken,
    BufferTooSmall,
};

pub const Scanner = struct {
    source: []const u8,
    line: usize,
    start: usize,
    current: usize,

    pub fn init(source: []const u8) Scanner {
        return Scanner{
            .source = source,
            .line = 1,
            .start = 0,
            .current = 0,
        };
    }

    inline fn is_at_end(self: *Scanner) bool {
        return self.current >= self.source.len;
    }

    // Returns 0 at end-of-source
    inline fn peek(self: *Scanner) u8 {
        if (self.is_at_end()) return 0;
        return self.source[self.current];
    }

    inline fn peek_next(self: *Scanner) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    inline fn advance(self: *Scanner) u8 {
        self.current += 1;
        return self.source[self.current - 1];
    }

    inline fn match(self: *Scanner, expected: u8) bool {
        if (self.is_at_end()) return false;
        if (self.source[self.current] != expected) return false;
        self.current += 1;
        return true;
    }

    inline fn make_token(self: *Scanner, token_type: TokenType) Token {
        return Token{
            .token_type = token_type,
            .lexeme = self.source[self.start..self.current],
            .line = self.line,
        };
    }

    inline fn is_identifier_starter(c: u8) bool {
        return ascii.isAlphabetic(c) or c == '_';
    }

    inline fn is_alpha(c: u8) bool {
        return ascii.isAlphabetic(c) or c == '_';
    }

    inline fn is_digit(c: u8) bool {
        return ascii.isDigit(c);
    }

    inline fn is_hex_digit(c: u8) bool {
        return ascii.isHex(c);
    }

    fn skip_whitespace(self: *Scanner) void {
        while (true) {
            switch (self.peek()) {
                ' ', '\r', '\t' => _ = self.advance(),
                '\n' => {
                    self.line += 1;
                    _ = self.advance();
                },
                '/' => {
                    if (self.peek_next() == '/') {
                        while (self.peek() != '\n' and !self.is_at_end())
                            _ = self.advance();
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn check_keyword(self: *Scanner, start: usize, rest: []const u8, token_type: TokenType) TokenType {
        const lexeme_len = self.current - self.start;
        const expected_len = start + rest.len;
        if (lexeme_len == expected_len and
            mem.eql(u8, self.source[self.start + start .. self.start + expected_len], rest))
        {
            return token_type;
        }
        return .IDENTIFIER;
    }

    fn identifier_type(self: *Scanner) TokenType {
        const len = self.current - self.start;
        switch (self.source[self.start]) {
            // Type annotations
            'N' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    'i' => return self.check_keyword(2, "l", .NIL_TYPE),
                    'e' => return self.check_keyword(2, "ver", .NEVER_TYPE),
                    'o' => return self.check_keyword(2, "ne", .NONE),
                    else => {},
                };
            },
            'B' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    'o' => return self.check_keyword(2, "ol", .BOOL_TYPE),
                    'u' => return self.check_keyword(2, "ffer", .BUFFER_TYPE),
                    else => {},
                };
            },
            'I' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    'n' => return self.check_keyword(2, "t", .INT_TYPE),
                    't' => return self.check_keyword(2, "erator", .ITERATOR_TYPE),
                    else => {},
                };
            },
            'E' => {
                if (len > 1) {
                    switch (self.source[self.start + 1]) {
                        'r' => {
                            if (len > 2) switch (self.source[self.start + 2]) {
                                'r' => {
                                    switch (self.source[self.start + 3]) {
                                        'o' => {
                                            return self.check_keyword(3, "or", .ERROR_TYPE);
                                        },
                                        else => {
                                            return self.check_keyword(3, "", .ERR);
                                        },
                                    }
                                },
                                else => {},
                            };
                        },
                        else => {},
                    }
                }
            },
            'F' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    'i' => return self.check_keyword(2, "le", .FILE_TYPE),
                    'l' => return self.check_keyword(2, "oat", .FLOAT_TYPE),
                    else => {},
                };
            },
            'C' => return self.check_keyword(1, "omplex", .COMPLEX_TYPE),
            'S' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    't' => return self.check_keyword(2, "ring", .STRING_TYPE),
                    'o' => return self.check_keyword(2, "me", .SOME),
                    else => {},
                };
            },
            'T' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    'u' => return self.check_keyword(2, "ple", .TUPLE_TYPE),
                    'a' => return self.check_keyword(2, "ble", .TABLE_TYPE),
                    else => {},
                };
            },
            'R' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    'a' => {
                        if (len > 2) switch (self.source[self.start + 2]) {
                            'n' => {
                                if (len > 3) switch (self.source[self.start + 3]) {
                                    'g' => return self.check_keyword(4, "e", .RANGE_TYPE),
                                    'd' => return self.check_keyword(4, "om", .RANDOM_TYPE),
                                    else => {},
                                };
                            },
                            else => {},
                        };
                    },
                    'e' => return self.check_keyword(2, "sult", .RESULT_TYPE),
                    else => {},
                };
            },
            'A' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    'n' => return self.check_keyword(2, "y", .ANY_TYPE),
                    'r' => return self.check_keyword(2, "ray", .ARRAY_TYPE),
                    else => {},
                };
            },
            'V' => return self.check_keyword(1, "ector", .VECTOR_TYPE),
            'M' => return self.check_keyword(1, "atrix", .MATRIX_TYPE),
            // Language keywords
            'a' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    's' => return self.check_keyword(2, "", .AS),
                    'n' => return self.check_keyword(2, "d", .AND),
                    else => {},
                };
            },
            'b' => return self.check_keyword(1, "reak", .BREAK),
            'c' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    'o' => return self.check_keyword(2, "ntinue", .CONTINUE),
                    else => {},
                };
            },
            'd' => return self.check_keyword(1, "efault", .DEFAULT),
            'e' => return self.check_keyword(1, "lse", .ELSE),
            'g' => return self.check_keyword(1, "ive", .GIVE),
            'i' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    'm' => return self.check_keyword(2, "pl", .IMPL),
                    'f' => return self.check_keyword(2, "", .IF),
                    'n' => return self.check_keyword(2, "", .IN),
                    else => {},
                };
            },
            'n' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    'o' => return self.check_keyword(2, "t", .NOT),
                    'i' => return self.check_keyword(2, "l", .NIL),
                    'e' => return self.check_keyword(2, "w", .NEW),
                    'a' => return self.check_keyword(2, "tive", .NATIVE),
                    else => {},
                };
            },
            'o' => return self.check_keyword(1, "r", .OR),
            'r' => return self.check_keyword(1, "eturn", .RETURN),
            's' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    't' => {
                        if (len > 2) switch (self.source[self.start + 2]) {
                            'a' => return self.check_keyword(3, "tic", .STATIC),
                            'r' => return self.check_keyword(3, "uct", .STRUCT),
                            else => {},
                        };
                    },
                    'h' => return self.check_keyword(2, "ape", .SHAPE),
                    else => {},
                };
            },
            'w' => return self.check_keyword(1, "hile", .WHILE),
            'v' => return self.check_keyword(1, "ar", .VAR),
            'f' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    'a' => return self.check_keyword(2, "lse", .FALSE),
                    'o' => return self.check_keyword(2, "r", .FOR),
                    'n' => return self.check_keyword(2, "", .FN),
                    'r' => return self.check_keyword(2, "om", .FROM),
                    else => {},
                };
            },
            'm' => return self.check_keyword(1, "atch", .MATCH),
            't' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    'r' => return self.check_keyword(2, "ue", .TRUE),
                    'y' => {
                        if (len > 2 and self.source[self.start + 2] == 'p') {
                            if (len > 3 and self.source[self.start + 3] == 'e') {
                                if (len == 4) return self.check_keyword(4, "", .TYPE);
                                return self.check_keyword(4, "of", .TYPEOF);
                            }
                        }
                    },
                    else => {},
                };
            },
            'u' => return self.check_keyword(1, "se", .USE),
            'p' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    'a' => return self.check_keyword(2, "nic", .PANIC),
                    'u' => return self.check_keyword(2, "b", .PUB),
                    else => {},
                };
            },
            'O' => {
                if (len > 1) switch (self.source[self.start + 1]) {
                    'k' => return self.check_keyword(2, "", .OK),
                    'p' => return self.check_keyword(2, "tion", .OPTION_TYPE),
                    else => {},
                };
            },
            else => {},
        }
        return .IDENTIFIER;
    }

    fn single_string(self: *Scanner) ScannerError!Token {
        while (!self.is_at_end()) {
            if (self.peek() == '\'') break;
            if (self.peek() == '\\') {
                _ = self.advance();
                if (!self.is_at_end()) _ = self.advance();
                continue;
            }
            if (self.peek() == '\n') self.line += 1;
            _ = self.advance();
        }
        if (self.is_at_end()) return ScannerError.UnterminatedString;
        _ = self.advance(); // closing quote
        return self.make_token(.STRING);
    }

    fn double_string(self: *Scanner) ScannerError!Token {
        while (!self.is_at_end()) {
            if (self.peek() == '"') break;
            if (self.peek() == '\\') {
                _ = self.advance();
                if (!self.is_at_end()) _ = self.advance();
                continue;
            }
            if (self.peek() == '\n') self.line += 1;
            _ = self.advance();
        }
        if (self.is_at_end()) return ScannerError.UnterminatedString;
        _ = self.advance(); // closing quote
        return self.make_token(.STRING);
    }

    fn number(self: *Scanner) Token {
        var fp_found = false;
        var bin_found = false;
        var hex_found = false;

        while (is_digit(self.peek())) _ = self.advance();

        if (self.peek() == '.' and is_digit(self.peek_next())) {
            fp_found = true;
            _ = self.advance();
            while (is_digit(self.peek())) _ = self.advance();
        } else if (self.peek() == 'b' and is_digit(self.peek_next())) {
            bin_found = true;
            _ = self.advance();
            while (is_digit(self.peek())) _ = self.advance();
        } else if (self.peek() == 'x' and is_hex_digit(self.peek_next())) {
            hex_found = true;
            _ = self.advance();
            while (is_hex_digit(self.peek())) _ = self.advance();
        }

        if (fp_found) return self.make_token(.FLOAT);
        if (bin_found) return self.make_token(.BINARY_INT);
        if (hex_found) return self.make_token(.HEX_INT);
        return self.make_token(.INT);
    }

    fn identifier(self: *Scanner) Token {
        while (is_alpha(self.peek()) or is_digit(self.peek())) _ = self.advance();
        return self.make_token(self.identifier_type());
    }

    fn scan_token(self: *Scanner) ScannerError!Token {
        self.skip_whitespace();
        self.start = self.current;

        if (self.is_at_end()) return self.make_token(.EOF);

        const c = self.advance();

        if (is_digit(c)) return self.number();
        if (is_identifier_starter(c)) return self.identifier();

        return switch (c) {
            ':' => self.make_token(if (self.match(':')) .COLON_COLON else .COLON),
            '(' => self.make_token(.LEFT_PAREN),
            ')' => self.make_token(.RIGHT_PAREN),
            '{' => self.make_token(.LEFT_BRACE),
            '}' => self.make_token(.RIGHT_BRACE),
            '[' => self.make_token(.LEFT_SQUARE),
            ']' => self.make_token(.RIGHT_SQUARE),
            '$' => if (self.match('[')) self.make_token(.DOLLAR_LEFT_SQUARE) else error.UnexpectedToken,
            ';' => self.make_token(.SEMICOLON),
            ',' => self.make_token(.COMMA),
            '.' => self.make_token(if (self.match('.')) .DOT_DOT else .DOT),
            '-' => if (self.match('>'))
                self.make_token(.ARROW)
            else
                self.make_token(if (self.match('=')) .MINUS_EQUAL else .MINUS),
            '+' => self.make_token(if (self.match('=')) .PLUS_EQUAL else .PLUS),
            '/' => self.make_token(if (self.match('=')) .SLASH_EQUAL else .SLASH),
            '\\' => self.make_token(if (self.match('=')) .BACK_SLASH_EQUAL else .BACKSLASH),
            '*' => if (self.match('*'))
                self.make_token(.STAR_STAR)
            else
                self.make_token(if (self.match('=')) .STAR_EQUAL else .STAR),
            '%' => self.make_token(if (self.match('=')) .PERCENT_EQUAL else .PERCENT),
            '!' => if (self.match('=')) self.make_token(.BANG_EQUAL) else error.UnexpectedToken,
            '=' => if (self.match('='))
                self.make_token(.EQUAL_EQUAL)
            else if (self.match('>'))
                self.make_token(.EQUAL_ARROW)
            else
                self.make_token(.EQUAL),
            '<' => if (self.match('<'))
                self.make_token(.LEFT_SHIFT)
            else
                self.make_token(if (self.match('=')) .LESS_EQUAL else .LESS),
            '>' => if (self.match('>'))
                self.make_token(.RIGHT_SHIFT)
            else
                self.make_token(if (self.match('=')) .GREATER_EQUAL else .GREATER),
            '"' => try self.double_string(),
            '\'' => try self.single_string(),
            '?' => self.make_token(.QUESTION_MARK),
            '&' => self.make_token(.AMPERSAND),
            '|' => self.make_token(.PIPE),
            '^' => self.make_token(.CARET),
            '~' => self.make_token(.TILDE),
            else => error.UnexpectedCharacter,
        };
    }

    pub fn scan(self: *Scanner, token_buf: []Token) ScannerError!usize {
        var buf_pos: usize = 0;
        while (true) {
            if (buf_pos == token_buf.len) return ScannerError.BufferTooSmall;
            const token = try self.scan_token();
            token_buf[buf_pos] = token;
            buf_pos += 1;
            if (token.token_type == .EOF) break;
        }
        return buf_pos;
    }
};

test "Scanner Tokenizes basic program" {
    var scanner: Scanner = Scanner.init("var hello = 'hello world'; var e: Error = Err('This is an error');");
    var token_buffer: [1024]Token = undefined;
    const token_count = try scanner.scan(&token_buffer);
    for (0..token_count) |i| {
        std.debug.print("Token: {s} Lexeme: {s}\n", .{ @tagName(token_buffer[i].token_type), token_buffer[i].lexeme });
    }
}
