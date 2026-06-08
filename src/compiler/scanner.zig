const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const DiagnosticsReporter = @import("../helpers/diagnostics.zig").DiagnosticsReporter;

/// Types of tokens that can be parsed by the scanner.
pub const TokenType = enum {
    /// '('
    LEFT_PAREN,
    /// ')'
    RIGHT_PAREN,
    /// '{'
    LEFT_BRACE,
    /// '}'
    RIGHT_BRACE,
    /// '['
    LEFT_SQUARE,
    /// ']'
    RIGHT_SQUARE,
    /// ','
    COMMA,
    /// '.'
    DOT,
    /// '..' used for range expressions (e.g. `1..5`)
    DOT_DOT,
    /// '-'
    MINUS,
    /// '+'
    PLUS,
    /// ';'
    SEMICOLON,
    /// '/'
    SLASH,
    /// '*'
    STAR,
    /// '**' Used for exponentiation (e.g. `2 ** 3`)
    STAR_STAR,
    /// '++' Use for concatenation (e.g. `a ++ b`)
    PLUS_PLUS,
    /// '%'
    PERCENT,
    /// ':'
    COLON,
    /// '->'
    ARROW,
    /// '!='
    NOT_EQUAL,
    /// '='
    EQUAL,
    /// '=='
    EQUAL_EQUAL,
    /// '=>'
    EQUAL_ARROW,
    /// '>'
    GREATER,
    /// '>='
    GREATER_EQUAL,
    /// '<'
    LESS,
    /// '<='
    LESS_EQUAL,
    /// '<<'
    LEFT_SHIFT,
    /// '>>'
    RIGHT_SHIFT,
    /// '&'
    AMPERSAND,
    /// '^'
    CARET,
    /// '|'
    PIPE,
    /// '~'
    TILDE,
    /// '+='
    PLUS_EQUAL,
    /// '-='
    MINUS_EQUAL,
    /// '*='
    STAR_EQUAL,
    /// '/='
    SLASH_EQUAL,
    /// '%='
    PERCENT_EQUAL,
    /// '::'
    COLON_COLON,
    /// A sequence of alphanumeric characters (e.g. `foo`, `bar`) starting with a letter or underscore
    IDENTIFIER,
    /// A string literal which may start with a single or double quote
    STRING,
    /// An integer literal
    INT,
    /// A floating point literal
    FLOAT,
    /// A binary integer literal (e.g. `0b1010`)
    BINARY_INT,
    /// A hexadecimal integer literal (e.g. `0x1A`)
    HEX_INT,
    /// 'and'
    AND,
    /// 'not'
    NOT,
    /// 'else'
    ELSE,
    /// 'false'
    FALSE,
    /// 'for'
    FOR,
    /// 'fn'
    FN,
    /// 'if'
    IF,
    /// 'in'
    IN,
    /// 'nil'
    NIL,
    /// 'or'
    OR,
    /// 'orelse'
    ORELSE,
    /// 'return'
    RETURN,
    /// 'true'
    TRUE,
    /// 'var'
    VAR,
    /// 'while'
    WHILE,
    /// 'break'
    BREAK,
    /// 'continue'
    CONTINUE,
    /// 'yield'
    YIELD,
    /// 'use'
    USE,
    /// 'from'
    FROM,
    /// 'pub'
    PUB,
    /// 'as'
    AS,
    /// 'match'
    MATCH,
    /// 'default'
    DEFAULT,
    /// 'give'
    GIVE,
    /// 'new'
    NEW,
    /// 'panic'
    PANIC,
    /// 'struct'
    STRUCT,
    /// 'shape'
    SHAPE,
    /// 'type'
    TYPE,
    /// 'static'
    STATIC,
    /// 'co'
    CO,
    /// 'enum'
    ENUM,
    /// 'error'
    ERROR,
    /// 'resume'
    RESUME,
    /// 'try'
    TRY,

    /// 'Nil'
    NIL_TYPE,
    /// 'Bool'
    BOOL_TYPE,
    /// 'Int'
    INT_TYPE,
    /// 'Float'
    FLOAT_TYPE,
    /// 'String'
    STRING_TYPE,
    /// 'Array'
    ARRAY_TYPE,
    /// 'Table'
    TABLE_TYPE,
    /// 'Range'
    RANGE_TYPE,
    /// 'Never'
    NEVER_TYPE,
    /// 'EOF'
    EOF,
};

pub const Token = struct {
    token_type: TokenType,
    lexeme: []const u8,
    line: usize,
    column: usize,
};

pub const ScannerError = error{
    UnterminatedString,
    UnexpectedCharacter,
    UnexpectedToken,
    BufferTooSmall, // only for scan()
} || std.mem.Allocator.Error;

pub const Scanner = struct {
    source: []const u8,
    line: usize,
    start: usize,
    current: usize,
    diagnostics: *DiagnosticsReporter,
    last_newline_pos: usize,
    file_path: []const u8,

    pub fn init(source: []const u8, diagnostics: *DiagnosticsReporter, file_path: []const u8) Scanner {
        return Scanner{
            .source = source,
            .line = 1,
            .start = 0,
            .current = 0,
            .diagnostics = diagnostics,
            .last_newline_pos = 0,
            .file_path = file_path,
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
        const c = self.source[self.current - 1];
        if (c == '\n') self.last_newline_pos = self.current;
        return c;
    }

    pub inline fn column(self: *Scanner) usize {
        return self.start - self.last_newline_pos + 1;
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
            .column = self.column(),
        };
    }

    inline fn is_alpha(c: u8) bool {
        return ascii.isAlphabetic(c) or c == '_';
    }

    inline fn is_digit(c: u8) bool {
        return ascii.isDigit(c);
    }

    inline fn is_binary_digit(c: u8) bool {
        return c == '0' or c == '1';
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
                    if (self.peek_next() != '/') return;
                    while (self.peek() != '\n' and !self.is_at_end())
                        _ = self.advance();
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
        const source = self.source[self.start..self.current];

        return switch (source[0]) {
            // Type annotations
            'A' => self.check_keyword(1, "rray", .ARRAY_TYPE),
            'B' => if (len > 1) switch (source[1]) {
                'o' => self.check_keyword(2, "ol", .BOOL_TYPE),
                else => .IDENTIFIER,
            } else .IDENTIFIER,
            'F' => self.check_keyword(1, "loat", .FLOAT_TYPE),
            'I' => self.check_keyword(1, "nt", .INT_TYPE),
            'N' => if (len > 1) switch (source[1]) {
                'i' => self.check_keyword(2, "l", .NIL_TYPE),
                'e' => self.check_keyword(2, "ver", .NEVER_TYPE),
                else => .IDENTIFIER,
            } else .IDENTIFIER,
            'R' => self.check_keyword(1, "ange", .RANGE_TYPE),
            'S' => self.check_keyword(1, "tring", .STRING_TYPE),
            'T' => self.check_keyword(1, "able", .TABLE_TYPE),

            // Language keywords
            'a' => if (len > 1) switch (source[1]) {
                's' => self.check_keyword(2, "", .AS),
                'n' => self.check_keyword(2, "d", .AND),
                else => .IDENTIFIER,
            } else .IDENTIFIER,
            'b' => self.check_keyword(1, "reak", .BREAK),
            'c' => if (len > 1) switch (source[1]) {
                'o' => if (len == 2) .CO else self.check_keyword(2, "ntinue", .CONTINUE),
                else => .IDENTIFIER,
            } else .IDENTIFIER,
            'd' => self.check_keyword(1, "efault", .DEFAULT),
            'e' => if (len > 1) switch (source[1]) {
                'l' => self.check_keyword(2, "se", .ELSE),
                'n' => self.check_keyword(2, "um", .ENUM),
                'r' => self.check_keyword(2, "ror", .ERROR),
                else => .IDENTIFIER,
            } else .IDENTIFIER,
            'f' => if (len > 1) switch (source[1]) {
                'a' => self.check_keyword(2, "lse", .FALSE),
                'n' => self.check_keyword(2, "", .FN),
                'o' => self.check_keyword(2, "r", .FOR),
                'r' => self.check_keyword(2, "om", .FROM),
                else => .IDENTIFIER,
            } else .IDENTIFIER,
            'g' => self.check_keyword(1, "ive", .GIVE),
            'i' => if (len > 1) switch (source[1]) {
                'f' => self.check_keyword(2, "", .IF),
                'n' => self.check_keyword(2, "", .IN),
                else => .IDENTIFIER,
            } else .IDENTIFIER,
            'm' => self.check_keyword(1, "atch", .MATCH),
            'n' => if (len > 1) switch (source[1]) {
                'o' => self.check_keyword(2, "t", .NOT),
                'i' => self.check_keyword(2, "l", .NIL),
                'e' => self.check_keyword(2, "w", .NEW),
                else => .IDENTIFIER,
            } else .IDENTIFIER,
            'o' => if (len > 1) switch (source[1]) {
                'r' => if (len == 2) .OR else self.check_keyword(2, "else", .ORELSE),
                else => .IDENTIFIER,
            } else .IDENTIFIER,
            'p' => if (len > 1) switch (source[1]) {
                'a' => self.check_keyword(2, "nic", .PANIC),
                'u' => self.check_keyword(2, "b", .PUB),
                else => .IDENTIFIER,
            } else .IDENTIFIER,
            'r' => if (len > 1) switch (source[1]) {
                'e' => if (len > 2) switch (source[2]) {
                    't' => self.check_keyword(3, "urn", .RETURN),
                    's' => self.check_keyword(3, "ume", .RESUME),
                    else => .IDENTIFIER,
                } else .IDENTIFIER,
                else => .IDENTIFIER,
            } else .IDENTIFIER,
            's' => if (len > 1) switch (source[1]) {
                't' => if (len > 2) switch (source[2]) {
                    'a' => self.check_keyword(3, "tic", .STATIC),
                    'r' => self.check_keyword(3, "uct", .STRUCT),
                    else => .IDENTIFIER,
                } else .IDENTIFIER,
                'h' => self.check_keyword(2, "ape", .SHAPE),
                else => .IDENTIFIER,
            } else .IDENTIFIER,
            'w' => self.check_keyword(1, "hile", .WHILE),
            'v' => self.check_keyword(1, "ar", .VAR),
            'y' => self.check_keyword(1, "ield", .YIELD),
            't' => if (len > 1) switch (source[1]) {
                'r' => if (len > 2) switch (source[2]) {
                    'u' => self.check_keyword(3, "e", .TRUE),
                    'y' => self.check_keyword(3, "", .TRY),
                    else => .IDENTIFIER,
                } else .IDENTIFIER,
                'y' => self.check_keyword(2, "pe", .TYPE),
                else => .IDENTIFIER,
            } else .IDENTIFIER,
            'u' => self.check_keyword(1, "se", .USE),
            else => .IDENTIFIER,
        };
    }

    fn string(self: *Scanner, quote: u8) ScannerError!Token {
        while (!self.is_at_end()) {
            const c = self.peek();
            if (c == quote) break;
            if (c == '\\') {
                _ = self.advance();
                if (!self.is_at_end()) _ = self.advance();
                continue;
            }
            if (c == '\n') self.line += 1;
            _ = self.advance();
        }
        if (self.is_at_end()) {
            try self.diagnostics.add_diagnostic(.{ .column = self.column(), .line = self.line, .severity = .Error, .message = "Unterminated string", .file_path = self.file_path, .stage = .Scanner });
            return ScannerError.UnterminatedString;
        }
        _ = self.advance(); // closing quote
        return self.make_token(.STRING);
    }

    fn number(self: *Scanner) Token {
        while (is_digit(self.peek())) _ = self.advance();

        if (self.peek() == '.' and is_digit(self.peek_next())) {
            _ = self.advance();
            while (is_digit(self.peek()) or self.peek() == 'e' or self.peek() == 'E') _ = self.advance();
            return self.make_token(.FLOAT);
        } else if (self.peek() == 'b' and is_binary_digit(self.peek_next())) {
            _ = self.advance();
            while (is_binary_digit(self.peek())) _ = self.advance();
            return self.make_token(.BINARY_INT);
        } else if (self.peek() == 'x' and is_hex_digit(self.peek_next())) {
            _ = self.advance();
            while (is_hex_digit(self.peek())) _ = self.advance();
            return self.make_token(.HEX_INT);
        }

        return self.make_token(.INT);
    }

    fn identifier(self: *Scanner) Token {
        while (is_alpha(self.peek()) or is_digit(self.peek())) _ = self.advance();
        return self.make_token(self.identifier_type());
    }

    pub fn scan_token(self: *Scanner) ScannerError!Token {
        self.skip_whitespace();
        self.start = self.current;

        if (self.is_at_end()) return self.make_token(.EOF);

        const c = self.advance();

        if (is_digit(c)) return self.number();
        if (is_alpha(c)) return self.identifier();

        return switch (c) {
            '(' => self.make_token(.LEFT_PAREN),
            ')' => self.make_token(.RIGHT_PAREN),
            '{' => self.make_token(.LEFT_BRACE),
            '}' => self.make_token(.RIGHT_BRACE),
            '[' => self.make_token(.LEFT_SQUARE),
            ']' => self.make_token(.RIGHT_SQUARE),
            ';' => self.make_token(.SEMICOLON),
            ',' => self.make_token(.COMMA),
            ':' => self.make_token(if (self.match(':')) .COLON_COLON else .COLON),
            '.' => self.make_token(if (self.match('.')) .DOT_DOT else .DOT),
            '-' => if (self.match('>'))
                self.make_token(.ARROW)
            else
                self.make_token(if (self.match('=')) .MINUS_EQUAL else .MINUS),
            '+' => self.make_token(if (self.match('=')) .PLUS_EQUAL else if (self.match('+')) .PLUS_PLUS else .PLUS),
            '/' => self.make_token(if (self.match('=')) .SLASH_EQUAL else .SLASH),
            '*' => if (self.match('*'))
                self.make_token(.STAR_STAR)
            else
                self.make_token(if (self.match('=')) .STAR_EQUAL else .STAR),
            '%' => self.make_token(if (self.match('=')) .PERCENT_EQUAL else .PERCENT),
            '!' => if (self.match('=')) self.make_token(.NOT_EQUAL) else error.UnexpectedToken,
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
            '"', '\'' => |q| self.string(q),
            '&' => self.make_token(.AMPERSAND),
            '|' => self.make_token(.PIPE),
            '^' => self.make_token(.CARET),
            '~' => self.make_token(.TILDE),
            else => {
                try self.diagnostics.add_diagnostic(.{ .column = self.column(), .line = self.line, .severity = .Error, .message = "Unexpected character", .stage = .Scanner, .file_path = self.file_path });
                return ScannerError.UnexpectedCharacter;
            },
        };
    }

    pub fn scan(self: *Scanner, token_buf: []Token) ScannerError!usize {
        var buf_pos: usize = 0;
        while (true) {
            if (buf_pos == token_buf.len) {
                try self.diagnostics.add_diagnostic(.{ .column = self.column(), .line = self.line, .severity = .Fatal, .message = "Buffer too small", .stage = .Scanner, .file_path = self.file_path });
                return ScannerError.BufferTooSmall;
            }
            const token = try self.scan_token();
            token_buf[buf_pos] = token;
            buf_pos += 1;
            if (token.token_type == .EOF) break;
        }
        return buf_pos;
    }
};
