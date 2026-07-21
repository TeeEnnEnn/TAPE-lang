const AST = @import("ast.zig");
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("scanner.zig").Token;
const TokenType = @import("scanner.zig").TokenType;
const MatchCase = AST.MatchCase;
const DiagnosticsReporter = @import("../diagnostics/diagnostics.zig").DiagnosticsReporter;
const Workspace = @import("workspace.zig").Workspace;
const Module = @import("workspace.zig").Module;
const WorkspaceError = @import("workspace.zig").WorkspaceError;

const std = @import("std");

const ScannerError = @import("scanner.zig").ScannerError;

pub const ParserError = ScannerError || std.mem.Allocator.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError || std.Io.RandomSecureError || WorkspaceError || error{
    UnexpectedToken,
};

pub const Parser = struct {
    workspace: *Workspace,
    scanner: Scanner,
    allocator: std.mem.Allocator,
    current: Token,
    previous: Token,
    io: std.Io,
    module: *Module,
    group: *std.Io.Group,

    pub fn init(allocator: std.mem.Allocator, workspace: *Workspace, module: *Module, io: std.Io, group: *std.Io.Group) !Parser {
        var parser = Parser{
            .allocator = allocator,
            .workspace = workspace,
            .module = module,
            .scanner = Scanner.init(module.file_contents),
            .current = Token{ .token_type = .EOF, .lexeme = "", .line = 0, .column = 0 },
            .previous = Token{ .token_type = .EOF, .lexeme = "", .line = 0, .column = 0 },
            .io = io,
            .group = group,
        };
        try parser.advance();
        return parser;
    }

    /// Advances the parser to the next token.
    fn advance(self: *Parser) !void {
        self.previous = self.current;
        while (true) {
            self.current = try self.scanner.scan_token();
            break;
        }
    }

    fn consume(self: *Parser, expected: TokenType, diagnostic_message: []const u8) ParserError!void {
        if (self.current.token_type == expected) {
            try self.advance();
            return;
        }
        try self.workspace.diagnostics_mutex.lock(self.io);
        try self.workspace.diagnostics.add_diagnostic(.{ .column = self.scanner.column(), .line = self.scanner.line, .stage = .Parser, .severity = .Error, .message = diagnostic_message, .file_path = self.module.filepath });
        self.workspace.diagnostics_mutex.unlock(self.io);
        return ParserError.UnexpectedToken;
    }

    /// Returns true if the current token matches the expected type, false otherwise.
    fn check(self: *Parser, expected: TokenType) bool {
        return self.current.token_type == expected;
    }

    /// Returns true if the current token matches the expected type (false otherwise), and advances if it does.
    fn match(self: *Parser, expected: TokenType) ParserError!bool {
        if (!self.check(expected)) {
            return false;
        }
        try self.advance();
        return true;
    }

    /// Parses an assignment expression.
    fn parse_assignment(self: *Parser) ParserError!*AST.ASTNode {
        const left = try self.parse_range();

        if (self.check(.EQUAL) or self.check(.PLUS_EQUAL) or self.check(.MINUS_EQUAL) or self.check(.STAR_EQUAL) or self.check(.SLASH_EQUAL) or self.check(.PERCENT_EQUAL)) {
            const operator = self.current;
            try self.advance();

            const right = try self.parse_assignment();

            const assign = try self.allocator.create(AST.AssignExpr);
            assign.* = .{
                .left = left,
                .operator = operator,
                .right = right,
                .line = operator.line,
                .column = operator.column,
            };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .assign_expr = assign };
            return node;
        }

        return left;
    }

    fn parse_range(self: *Parser) ParserError!*AST.ASTNode {
        const left = try self.parse_logical_or();
        if (self.check(.DOT_DOT)) {
            const operator = self.current;
            try self.advance();
            const right = try self.parse_logical_or();

            const binary = try self.allocator.create(AST.BinaryExpr);
            binary.* = .{
                .operator = operator,
                .left = left,
                .right = right,
                .line = operator.line,
                .column = operator.column,
            };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .binary_expr = binary };
            return node;
        }
        return left;
    }

    fn parse_logical_or(self: *Parser) ParserError!*AST.ASTNode {
        var left = try self.parse_logical_and();
        while (self.check(.OR) or self.check(.ORELSE)) {
            const operator = self.current;
            try self.advance();
            const right = try self.parse_logical_and();
            const binary = try self.allocator.create(AST.BinaryExpr);
            binary.* = .{
                .operator = operator,
                .left = left,
                .right = right,
                .line = operator.line,
                .column = operator.column,
            };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{
                .binary_expr = binary,
            };
            left = node;
        }
        return left;
    }

    fn parse_logical_and(self: *Parser) ParserError!*AST.ASTNode {
        var left = try self.parse_bit_or();
        while (self.check(.AND)) {
            const operator = self.current;
            try self.advance();
            const right = try self.parse_bit_or();
            const binary = try self.allocator.create(AST.BinaryExpr);
            binary.* = .{
                .operator = operator,
                .left = left,
                .right = right,
                .line = operator.line,
                .column = operator.column,
            };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{
                .binary_expr = binary,
            };
            left = node;
        }
        return left;
    }

    fn parse_bit_or(self: *Parser) ParserError!*AST.ASTNode {
        var left = try self.parse_bit_xor();
        while (self.check(.PIPE)) {
            const operator = self.current;
            try self.advance();
            const right = try self.parse_bit_xor();
            const binary = try self.allocator.create(AST.BinaryExpr);
            binary.* = .{
                .operator = operator,
                .left = left,
                .right = right,
                .line = operator.line,
                .column = operator.column,
            };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{
                .binary_expr = binary,
            };
            left = node;
        }
        return left;
    }

    fn parse_bit_xor(self: *Parser) ParserError!*AST.ASTNode {
        var left = try self.parse_bit_and();
        while (self.check(.CARET)) {
            const operator = self.current;
            try self.advance();
            const right = try self.parse_bit_and();
            const binary = try self.allocator.create(AST.BinaryExpr);
            binary.* = .{
                .operator = operator,
                .left = left,
                .right = right,
                .line = operator.line,
                .column = operator.column,
            };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{
                .binary_expr = binary,
            };
            left = node;
        }
        return left;
    }

    fn parse_bit_and(self: *Parser) ParserError!*AST.ASTNode {
        var left = try self.parse_equality();
        while (self.check(.AMPERSAND)) {
            const operator = self.current;
            try self.advance();
            const right = try self.parse_equality();
            const binary = try self.allocator.create(AST.BinaryExpr);
            binary.* = .{
                .operator = operator,
                .left = left,
                .right = right,
                .line = operator.line,
                .column = operator.column,
            };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{
                .binary_expr = binary,
            };
            left = node;
        }
        return left;
    }

    fn parse_equality(self: *Parser) ParserError!*AST.ASTNode {
        var left = try self.parse_comparison();
        while (self.check(.EQUAL_EQUAL) or self.check(.NOT_EQUAL)) {
            const operator = self.current;
            try self.advance();
            const right = try self.parse_comparison();
            const binary = try self.allocator.create(AST.BinaryExpr);
            binary.* = .{
                .operator = operator,
                .left = left,
                .right = right,
                .line = operator.line,
                .column = operator.column,
            };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{
                .binary_expr = binary,
            };
            left = node;
        }
        return left;
    }

    fn parse_comparison(self: *Parser) ParserError!*AST.ASTNode {
        var left = try self.parse_bit_shift();
        while (self.check(.LESS) or self.check(.LESS_EQUAL) or self.check(.GREATER) or self.check(.GREATER_EQUAL)) {
            const operator = self.current;
            try self.advance();
            const right = try self.parse_bit_shift();
            const binary = try self.allocator.create(AST.BinaryExpr);
            binary.* = .{
                .operator = operator,
                .left = left,
                .right = right,
                .line = operator.line,
                .column = operator.column,
            };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{
                .binary_expr = binary,
            };
            left = node;
        }
        return left;
    }

    fn parse_bit_shift(self: *Parser) ParserError!*AST.ASTNode {
        var left = try self.parse_term();
        while (self.check(.LEFT_SHIFT) or self.check(.RIGHT_SHIFT)) {
            const operator = self.current;
            try self.advance();
            const right = try self.parse_term();
            const binary = try self.allocator.create(AST.BinaryExpr);
            binary.* = .{
                .operator = operator,
                .left = left,
                .right = right,
                .line = operator.line,
                .column = operator.column,
            };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{
                .binary_expr = binary,
            };
            left = node;
        }
        return left;
    }

    fn parse_term(self: *Parser) ParserError!*AST.ASTNode {
        var left = try self.parse_factor();
        while (self.check(.PLUS) or self.check(.MINUS) or self.check(.PLUS_PLUS)) {
            const operator = self.current;
            try self.advance();
            const right = try self.parse_factor();

            const binary = try self.allocator.create(AST.BinaryExpr);
            binary.* = .{
                .operator = operator,
                .left = left,
                .right = right,
                .line = operator.line,
                .column = operator.column,
            };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{
                .binary_expr = binary,
            };
            left = node;
        }
        return left;
    }

    fn parse_factor(self: *Parser) ParserError!*AST.ASTNode {
        var left = try self.parse_unary();
        while (self.check(.STAR) or self.check(.STAR_STAR) or self.check(.PERCENT) or self.check(.SLASH)) {
            const operator = self.current;
            try self.advance();
            const right = try self.parse_unary();

            const binary = try self.allocator.create(AST.BinaryExpr);
            binary.* = .{
                .operator = operator,
                .left = left,
                .right = right,
                .line = operator.line,
                .column = operator.column,
            };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{
                .binary_expr = binary,
            };
            left = node;
        }
        return left;
    }

    fn parse_unary(self: *Parser) ParserError!*AST.ASTNode {
        if (self.check(.TILDE) or self.check(.MINUS) or self.check(.NOT) or self.check(.RESUME) or self.check(.TRY)) {
            const operator = self.current;
            try self.advance();

            // Unaries chain right-to-left
            const right = try self.parse_unary();

            switch (operator.token_type) {
                .RESUME => {
                    const resume_node = try self.allocator.create(AST.ResumeExpr);
                    resume_node.* = .{ .expr = right, .line = operator.line, .column = operator.column };

                    const node = try self.allocator.create(AST.ASTNode);
                    node.* = .{ .resume_expr = resume_node };
                    return node;
                },
                .TRY => {
                    const try_node = try self.allocator.create(AST.TryExpr);
                    try_node.* = .{ .expr = right, .line = operator.line, .column = operator.column };

                    const node = try self.allocator.create(AST.ASTNode);
                    node.* = .{ .try_expr = try_node };
                    return node;
                },
                else => {
                    // standard mathematical/logical unaries (~, -, not)
                    const unary = try self.allocator.create(AST.UnaryExpr);
                    unary.* = .{ .operator = operator, .expr = right, .line = operator.line, .column = operator.column };

                    const node = try self.allocator.create(AST.ASTNode);
                    node.* = .{ .unary_expr = unary };
                    return node;
                },
            }
        }

        // If no unary, go to next precedence
        return try self.parse_cast();
    }

    fn parse_cast(self: *Parser) ParserError!*AST.ASTNode {
        var expr = try self.parse_postfix();

        while (try self.match(.AS)) {
            const type_node = try self.parse_type_expression();

            const cast = try self.allocator.create(AST.CastExpr);
            cast.* = .{ .expr = expr, .type = type_node, .line = self.previous.line, .column = self.previous.column };

            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .cast_expr = cast };
            expr = node;
        }
        return expr;
    }

    fn parse_postfix(self: *Parser) ParserError!*AST.ASTNode {
        var expr = try self.parse_primary();

        while (true) {
            if (try self.match(.LEFT_PAREN)) {
                // Function Call
                var args: std.ArrayList(*AST.ASTNode) = .empty;
                if (!self.check(.RIGHT_PAREN)) {
                    while (true) {
                        try args.append(self.allocator, try self.parse_expression());
                        if (!try self.match(.COMMA)) break;
                    }
                }
                try self.consume(.RIGHT_PAREN, "Expected ')' after function arguments");

                const call = try self.allocator.create(AST.CallExpr);
                call.* = .{ .expr = expr, .args = try args.toOwnedSlice(self.allocator), .line = self.previous.line, .column = self.previous.column };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .call_expr = call };
                expr = node;
            } else if (try self.match(.LEFT_SQUARE)) {
                // Index
                const index = try self.parse_expression();
                try self.consume(.RIGHT_SQUARE, "Expected ']' after index expression");

                const index_expr = try self.allocator.create(AST.IndexExpr);
                index_expr.* = .{ .expr = expr, .index = index, .line = self.previous.line, .column = self.previous.column };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .index_expr = index_expr };
                expr = node;
            } else if (try self.match(.DOT)) {
                // dot member access
                try self.consume(.IDENTIFIER, "Expected identifier after '.'"); // TODO: make this also allow for numbers for tuple indexing
                const member = self.previous;

                const inst_expr = try self.allocator.create(AST.DotExpr);
                inst_expr.* = .{ .expr = expr, .member = member, .line = member.line, .column = member.column };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .dot_expr = inst_expr };
                expr = node;
            } else if (try self.match(.COLON_COLON)) {
                // Static Member
                try self.consume(.IDENTIFIER, "Expected identifier after '::'");
                const member = self.previous;

                const static_expr = try self.allocator.create(AST.StaticMemberExpr);
                static_expr.* = .{ .expr = expr, .member = member, .line = member.line, .column = member.column };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .static_member_expr = static_expr };
                expr = node;
            } else {
                break;
            }
        }
        return expr;
    }

    fn parse_primary(self: *Parser) ParserError!*AST.ASTNode {
        if (try self.match(.CO)) {
            return try self.parse_anonymous_coroutine();
        } else if (try self.match(.FN)) {
            return try self.parse_anonymous_function();
        } else if (self.check(.TRUE) or self.check(.FALSE) or self.check(.STRING) or self.check(.INT) or self.check(.FLOAT) or self.check(.NIL)) {
            return try self.parse_literal();
        } else if (self.check(.IDENTIFIER)) {
            return try self.parse_identifier_expression();
        } else if (try self.match(.LEFT_SQUARE)) {
            return try self.parse_array_literal();
        } else if (try self.match(.LEFT_BRACE)) {
            return try self.parse_table_literal();
        } else if (self.check(.LEFT_PAREN)) {
            return try self.parse_group_or_tuple();
        } else if (try self.match(.NEW)) {
            return try self.parse_new_expression();
        } else if (try self.match(.MATCH)) {
            return try self.parse_match_expression();
        } else {
            try self.workspace.diagnostics_mutex.lock(self.io);
            try self.workspace.diagnostics.add_diagnostic(.{ .column = self.scanner.column(), .line = self.scanner.line, .stage = .Parser, .severity = .Error, .message = "Unexpected token", .file_path = self.module.filepath });
            self.workspace.diagnostics_mutex.unlock(self.io);
            return ParserError.UnexpectedToken;
        }
    }

    fn parse_literal(self: *Parser) ParserError!*AST.ASTNode {
        const token = self.current;
        switch (token.token_type) {
            TokenType.STRING => {
                try self.advance();
                const literal = try self.allocator.create(AST.StrLit);
                literal.* = .{ .value = token.lexeme[1 .. token.lexeme.len - 1], .line = token.line, .column = token.column };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .str_lit = literal };
                return node;
            },
            TokenType.INT => {
                try self.advance();
                const literal = try self.allocator.create(AST.IntLit);
                literal.* = .{ .value = try std.fmt.parseInt(i64, token.lexeme, 10), .line = token.line, .column = token.column };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .int_lit = literal };
                return node;
            },
            TokenType.FLOAT => {
                try self.advance();
                const literal = try self.allocator.create(AST.FloatLit);
                literal.* = .{ .value = try std.fmt.parseFloat(f64, token.lexeme), .line = token.line, .column = token.column };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .float_lit = literal };
                return node;
            },
            TokenType.BINARY_INT => {
                try self.advance();
                const literal = try self.allocator.create(AST.IntLit);
                literal.* = .{ .value = try std.fmt.parseInt(i64, token.lexeme[2..], 2), .line = token.line, .column = token.column };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .int_lit = literal };
                return node;
            },
            TokenType.HEX_INT => {
                try self.advance();
                const literal = try self.allocator.create(AST.IntLit);
                literal.* = .{ .value = try std.fmt.parseInt(i64, token.lexeme[2..], 16), .line = token.line, .column = token.column };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .int_lit = literal };
                return node;
            },
            TokenType.TRUE => {
                try self.advance();
                const literal = try self.allocator.create(AST.BoolLit);
                literal.* = .{ .value = true, .line = token.line, .column = token.column };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .bool_lit = literal };
                return node;
            },
            TokenType.FALSE => {
                try self.advance();
                const literal = try self.allocator.create(AST.BoolLit);
                literal.* = .{ .value = false, .line = token.line, .column = token.column };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .bool_lit = literal };
                return node;
            },
            TokenType.NIL => {
                try self.advance();
                const literal = try self.allocator.create(AST.NilLit);
                literal.* = .{ .line = token.line, .column = token.column };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .nil_lit = literal };
                return node;
            },
            else => {
                try self.workspace.diagnostics_mutex.lock(self.io);
                try self.workspace.diagnostics.add_diagnostic(.{ .column = self.scanner.column(), .line = self.scanner.line, .stage = .Parser, .severity = .Error, .message = "Unexpected token", .file_path = self.module.filepath });
                self.workspace.diagnostics_mutex.unlock(self.io);
                return ParserError.UnexpectedToken;
            },
        }
    }

    fn parse_group_or_tuple(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_PAREN, "Expected '(' at the start of a group or tuple");

        // Empty tuple: ()
        if (try self.match(.RIGHT_PAREN)) {
            const empty_tuple = try self.allocator.create(AST.TupleExpr);
            empty_tuple.* = .{ .exprs = &[_]*AST.ASTNode{}, .line = self.previous.line, .column = self.previous.column };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .tuple_expr = empty_tuple };
            return node;
        }

        const first_expr = try self.parse_expression();

        if (try self.match(.COMMA)) {
            // It's a tuple: (expr,) or (expr, expr)
            var elements: std.ArrayList(*AST.ASTNode) = .empty;
            try elements.append(self.allocator, first_expr);

            if (!self.check(.RIGHT_PAREN)) {
                while (true) {
                    try elements.append(self.allocator, try self.parse_expression());
                    if (!try self.match(.COMMA)) break;
                }
            }
            try self.consume(.RIGHT_PAREN, "Expected ')' at the end of a tuple");

            const tuple_expr = try self.allocator.create(AST.TupleExpr);
            tuple_expr.* = .{ .exprs = try elements.toOwnedSlice(self.allocator), .resolved_type = 0, .line = self.previous.line, .column = self.previous.column };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .tuple_expr = tuple_expr };
            return node;
        } else {
            // It's a group: (expr)
            try self.consume(.RIGHT_PAREN, "Expected ')' at the end of a grouping expression");
            const group = try self.allocator.create(AST.GroupExpr);
            group.* = .{ .expr = first_expr, .resolved_type = 0, .line = self.previous.line, .column = self.previous.column };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .group_expr = group };
            return node;
        }
    }

    fn parse_new_expression(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER, "Expected identifier after 'new'");
        const struct_name = self.previous;

        try self.consume(.LEFT_BRACE, "Expected '{' to start struct initialization");
        var fields: std.ArrayList(AST.StructInitField) = .empty;

        if (!self.check(.RIGHT_BRACE)) {
            while (true) {
                try self.consume(.IDENTIFIER, "Expected field name after");
                const field_name = self.previous;
                try self.consume(.EQUAL, "Expected '=' after field name to initialize it");
                const value = try self.parse_expression();

                try fields.append(self.allocator, AST.StructInitField{ .name = field_name, .value = value });

                if (!try self.match(.COMMA)) break;
            }
        }
        try self.consume(.RIGHT_BRACE, "Expected '}' to end struct initialization");

        const new_expr = try self.allocator.create(AST.NewExpr);
        new_expr.* = .{ .struct_name = struct_name, .fields = try fields.toOwnedSlice(self.allocator), .resolved_type = 0, .line = struct_name.line, .column = struct_name.column };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .new_expr = new_expr };
        return node;
    }

    fn parse_identifier_expression(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER, "Expected identifier");
        const token = self.previous;
        const identifier = try self.allocator.create(AST.IdentifierExpr);
        identifier.* = .{ .name = token, .line = token.line, .column = token.column };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .identifier_expr = identifier };
        return node;
    }

    fn parse_anonymous_coroutine(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_PAREN, "Expected '(' to start anonymous coroutine parameter list.");
        var params: std.ArrayList(*AST.TypedNamedField) = .empty;

        if (!self.check(.RIGHT_PAREN)) {
            while (true) {
                const param_node = try self.parse_typed_named_field();
                try params.append(self.allocator, param_node);
                if (!try self.match(.COMMA)) break;
            }
        }
        try self.consume(.RIGHT_PAREN, "Expected ')' to end anonymous coroutine parameter list.");

        try self.consume(.ARROW, "Expected '->' to separate anonymous coroutine parameter list from return type.");
        try self.consume(.LEFT_PAREN, "Expected '(' to start anonymous coroutine yield, return type annotation.");
        const yield_type = try self.parse_type_expression();
        try self.consume(.COMMA, "Expected ',' to separate yield type from return type.");
        const return_type = try self.parse_type_expression();
        try self.consume(.RIGHT_PAREN, "Expected ')' to end anonymous coroutine yield, return type annotation.");

        const body = try self.parse_statement();

        const anon = try self.allocator.create(AST.AnonCoExpr);
        anon.* = .{
            .params = try params.toOwnedSlice(self.allocator),
            .return_type_annotation = return_type,
            .yield_type_annotation = yield_type,
            .body = body,
            .line = self.previous.line,
            .column = self.previous.column,
        };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .anon_co_expr = anon };
        return node;
    }

    fn parse_anonymous_function(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_PAREN, "Expected '(' to start anonymous function parameter list.");
        var params: std.ArrayList(*AST.TypedNamedField) = .empty;

        if (!self.check(.RIGHT_PAREN)) {
            while (true) {
                const param_node = try self.parse_typed_named_field(); // Helper to parse "name: Type"
                try params.append(self.allocator, param_node);
                if (!try self.match(.COMMA)) break;
            }
        }
        try self.consume(.RIGHT_PAREN, "Expected ')' to end anonymous function parameter list.");

        try self.consume(.ARROW, "Expected '->' to separate anonymous function parameter list from return type.");
        const return_type = try self.parse_type_expression();

        const body = try self.parse_statement();

        const anon = try self.allocator.create(AST.AnonFnExpr);
        anon.* = .{
            .params = try params.toOwnedSlice(self.allocator),
            .return_type_annotation = return_type,
            .body = body,
            .line = self.previous.line,
            .column = self.previous.column,
        };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .anon_fn_expr = anon };
        return node;
    }

    fn parse_typed_named_field(self: *Parser) ParserError!*AST.TypedNamedField {
        try self.consume(.IDENTIFIER, "Expected identifier for typed named field.");
        const token = self.previous;
        try self.consume(.COLON, "Expected ':' to separate identifier from type annotation.");
        const type_ = try self.parse_type_expression();
        const named_field = try self.allocator.create(AST.TypedNamedField);
        named_field.* = .{ .name = token, .type_annotation = type_ };
        return named_field;
    }

    fn parse_struct_field(self: *Parser, is_public: bool, is_static: bool) ParserError!*AST.TypedNamedStructField {
        try self.consume(.IDENTIFIER, "Expected identifier for struct field.");
        const token = self.previous;
        try self.consume(.COLON, "Expected ':' to separate identifier from type annotation.");
        const type_ = try self.parse_type_expression();
        var has_default = false;
        var default_value: ?*AST.ASTNode = null;
        if (try self.match(.EQUAL)) {
            default_value = try self.parse_expression();
            has_default = true;
        }
        const field = try self.allocator.create(AST.TypedNamedStructField);
        field.* = .{ .name = token, .type_annotation = type_, .default_value = default_value, .has_default = has_default, .is_pub = is_public, .is_static = is_static };
        return field;
    }

    fn parse_type_expression(self: *Parser) ParserError!*AST.ASTNode {
        var left: *AST.ASTNode = undefined;

        if (try self.match(.SHAPE)) {
            left = try self.parse_shape_expression();
        } else if (try self.match(.FN)) {
            // Function Type: fn (Int, Float) -> Bool
            try self.consume(.LEFT_PAREN, "Expected '(' to start function type parameters.");
            var params: std.ArrayList(*AST.ASTNode) = .empty;
            if (!self.check(.RIGHT_PAREN)) {
                while (true) {
                    try params.append(self.allocator, try self.parse_type_expression());
                    if (!try self.match(.COMMA)) break;
                }
            }
            try self.consume(.RIGHT_PAREN, "Expected ')' to end function type parameters.");

            try self.consume(.ARROW, "Expected '->' to separate function type parameters and return type.");
            const return_type = try self.parse_type_expression();

            const fn_type = try self.allocator.create(AST.FnType);
            fn_type.* = .{ .params = try params.toOwnedSlice(self.allocator), .return_type = return_type };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .fn_type = fn_type };
            left = node;
        } else if (try self.match(.CO)) {
            // Coroutine Type: co (Int, Float) -> (Bool, Int)
            try self.consume(.LEFT_PAREN, "Expected '(' to start coroutine type parameters.");
            var params: std.ArrayList(*AST.ASTNode) = .empty;
            if (!self.check(.RIGHT_PAREN)) {
                while (true) {
                    try params.append(self.allocator, try self.parse_type_expression());
                    if (!try self.match(.COMMA)) break;
                }
            }
            try self.consume(.RIGHT_PAREN, "Expected ')' to end coroutine type parameters.");

            try self.consume(.ARROW, "Expected '->' to separate coroutine type parameters and return type.");
            try self.consume(.CO, "Expected 'co' to start coroutine type.");
            try self.consume(.LEFT_SQUARE, "Expected '[' to start coroutine type return type.");
            const yield_type = try self.parse_type_expression();
            try self.consume(.COMMA, "Expected ',' to separate coroutine type return type and yield type.");
            const return_type = try self.parse_type_expression();
            try self.consume(.RIGHT_SQUARE, "Expected ']' to end coroutine type return type.");

            const co_type = try self.allocator.create(AST.CoType);
            co_type.* = .{ .params = try params.toOwnedSlice(self.allocator), .return_type = return_type, .yield_type = yield_type };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .co_type = co_type };
            left = node;
        } else if (try self.match(.NIL_TYPE)) {
            const nil_type = try self.allocator.create(AST.NilType);
            nil_type.* = .{};
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .nil_type = nil_type };
            left = node;
        } else if (try self.match(.BOOL_TYPE)) {
            const bool_type = try self.allocator.create(AST.BoolType);
            bool_type.* = .{};
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .bool_type = bool_type };
            left = node;
        } else if (try self.match(.INT_TYPE)) {
            const int_type = try self.allocator.create(AST.IntType);
            int_type.* = .{};
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .int_type = int_type };
            left = node;
        } else if (try self.match(.FLOAT_TYPE)) {
            const float_type = try self.allocator.create(AST.FloatType);
            float_type.* = .{};
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .float_type = float_type };
            left = node;
        } else if (try self.match(.STRING_TYPE)) {
            const string_type = try self.allocator.create(AST.StringType);
            string_type.* = .{};
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .string_type = string_type };
            left = node;
        } else if (try self.match(.NEVER_TYPE)) {
            const never_type = try self.allocator.create(AST.NeverType);
            never_type.* = .{};
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .never_type = never_type };
            left = node;
        } else if (try self.match(.ARRAY_TYPE)) {
            try self.consume(.LEFT_SQUARE, "Expected '[' to start array type.");
            const element = try self.parse_type_expression();
            try self.consume(.RIGHT_SQUARE, "Expected ']' to end array type.");
            const array_type = try self.allocator.create(AST.ArrayType);
            array_type.* = .{ .element_type = element };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .array_type = array_type };
            left = node;
        } else if (try self.match(.TABLE_TYPE)) {
            try self.consume(.LEFT_SQUARE, "Expected '[' to start table type.");
            const key = try self.parse_type_expression();
            try self.consume(.COMMA, "Expected ',' to separate key type from value type.");
            const val = try self.parse_type_expression();
            try self.consume(.RIGHT_SQUARE, "Expected ']' to end table type.");
            const table_type = try self.allocator.create(AST.TableType);
            table_type.* = .{ .key_type = key, .element_type = val };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .table_type = table_type };
            left = node;
        } else if (try self.match(.RANGE_TYPE)) {
            try self.consume(.LEFT_SQUARE, "Expected '[' to start range type.");
            const start = try self.parse_type_expression();
            try self.consume(.COMMA, "Expected ',' to separate start from end.");
            const end = try self.parse_type_expression();
            var step: u32 = 1;
            if (try self.match(.COMMA)) {
                try self.consume(.INT, "Expected integer for step size.");
                step = try std.fmt.parseInt(u32, self.previous.lexeme, 10);
            }
            try self.consume(.RIGHT_SQUARE, "Expected ']' to end range type.");
            const range_type = try self.allocator.create(AST.RangeType);
            range_type.* = .{ .start = start, .end = end, .step = step };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .range_type = range_type };
            left = node;
        } else if (try self.match(.LEFT_PAREN)) {
            // Tuple type: (Int, Float)
            var elements: std.ArrayList(*AST.ASTNode) = .empty;
            if (!self.check(.RIGHT_PAREN)) {
                while (true) {
                    try elements.append(self.allocator, try self.parse_type_expression());
                    if (!try self.match(.COMMA)) break;
                }
            }
            try self.consume(.RIGHT_PAREN, "Expected ')' to end tuple type.");

            const tuple_type = try self.allocator.create(AST.TupleType);
            tuple_type.* = .{ .element_types = try elements.toOwnedSlice(self.allocator) };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .tuple_type = tuple_type };
            left = node;
        } else {
            // Identifiers and Generics: Array[Int]
            try self.consume(.IDENTIFIER, "Expected identifier for type expression.");
            const name = self.previous;

            var generic_args: ?[]*AST.ASTNode = null;
            if (try self.match(.LEFT_SQUARE)) {
                var args: std.ArrayList(*AST.ASTNode) = .empty;
                while (true) {
                    try args.append(self.allocator, try self.parse_type_expression());
                    if (!try self.match(.COMMA)) break;
                }
                try self.consume(.RIGHT_SQUARE, "Expected ']' to end generic argument list.");
                generic_args = try args.toOwnedSlice(self.allocator);
            }

            const id_type = try self.allocator.create(AST.IdentifierType);
            id_type.* = .{ .name = name, .generic_args = generic_args, .source_file = self.module.filepath };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .identifier_type = id_type };
            left = node;
        }

        // Union Type handling (Type | Type)
        while (try self.match(.PIPE)) {
            const right = try self.parse_type_expression();
            const union_type = try self.allocator.create(AST.UnionType);
            union_type.* = .{ .left = left, .right = right };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .union_type = union_type };
            left = node;
        }

        return left;
    }

    fn parse_table_literal(self: *Parser) ParserError!*AST.ASTNode {
        var key_types: std.ArrayList(*AST.ASTNode) = .empty;
        var value_types: std.ArrayList(*AST.ASTNode) = .empty;

        while (true) {
            const key_type = try self.parse_expression();
            try self.consume(.COLON, "Expected ':' to separate key from value.");
            const value_type = try self.parse_expression();
            try key_types.append(self.allocator, key_type);
            try value_types.append(self.allocator, value_type);
            if (self.check(.RIGHT_BRACE)) {
                break;
            }
            try self.consume(.COMMA, "Expected ',' to separate key-value pairs in table literal.");
        }
        try self.consume(.RIGHT_BRACE, "Expected '}' to end table literal.");

        const table_literal = try self.allocator.create(AST.TableExpr);
        table_literal.* = .{
            .keys = try key_types.toOwnedSlice(self.allocator),
            .values = try value_types.toOwnedSlice(self.allocator),
            .line = self.previous.line,
            .column = self.previous.column,
        };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .table_expr = table_literal };

        return node;
    }

    fn parse_array_literal(self: *Parser) ParserError!*AST.ASTNode {
        var elements: std.ArrayList(*AST.ASTNode) = .empty;
        while (true) {
            const element = try self.parse_expression();
            try elements.append(self.allocator, element);
            if (self.check(.RIGHT_SQUARE)) {
                break;
            }
            try self.consume(.COMMA, "Expected ',' to separate array elements.");
        }
        try self.consume(.RIGHT_SQUARE, "Expected ']' to end array literal.");

        const array_literal = try self.allocator.create(AST.ArrayExpr);
        array_literal.* = .{
            .elements = try elements.toOwnedSlice(self.allocator),
            .line = self.previous.line,
            .column = self.previous.column,
        };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .array_expr = array_literal };

        return node;
    }

    fn parse_var_declaration(self: *Parser, is_pub: bool) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER, "Expected identifier for variable declaration.");
        const name = self.previous;

        var type_annotation: ?*AST.ASTNode = null;
        if (try self.match(.COLON)) {
            type_annotation = try self.parse_type_expression();
        }

        try self.consume(.EQUAL, "Expected '=' to separate variable name from initializer.");
        const initializer = try self.parse_expression();
        try self.consume(.SEMICOLON, "Expected ';' to end variable declaration.");

        const var_decl = try self.allocator.create(AST.VarDecl);
        var_decl.* = .{
            .modifier_pub = is_pub,
            .name = name,
            .type_annotation = type_annotation,
            .initializer = initializer,
            .line = name.line,
            .column = name.column,
        };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .var_decl = var_decl };

        return node;
    }

    fn parse_function_declaration(self: *Parser, is_pub: bool, is_static: bool) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER, "Expected identifier for function declaration.");
        const name = self.previous;

        try self.consume(.LEFT_PAREN, "Expected '(' to start function parameters.");
        var params: std.ArrayList(*AST.TypedNamedField) = .empty;

        if (!self.check(.RIGHT_PAREN)) {
            while (true) {
                const param = try self.parse_typed_named_field();
                try params.append(self.allocator, param);
                if (!try self.match(.COMMA)) break;
            }
        }
        try self.consume(.RIGHT_PAREN, "Expected ')' to end function parameters.");

        try self.consume(.ARROW, "Expected '->' to separate parameters from return type.");
        const return_type = try self.parse_type_expression();

        const body = try self.parse_statement();

        const fn_decl = try self.allocator.create(AST.FnDecl);
        fn_decl.* = .{
            .modifier_pub = is_pub,
            .modifier_static = is_static,
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type_annotation = return_type,
            .body = body,
            .line = name.line,
            .column = name.column,
        };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .fn_decl = fn_decl };

        return node;
    }

    fn parse_coroutine_declaration(self: *Parser, is_pub: bool, is_static: bool) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER, "Expected identifier for coroutine declaration.");
        const name = self.previous;

        try self.consume(.LEFT_PAREN, "Expected '(' to start coroutine parameters.");
        var params: std.ArrayList(*AST.TypedNamedField) = .empty;

        if (!self.check(.RIGHT_PAREN)) {
            while (true) {
                const param = try self.parse_typed_named_field();
                try params.append(self.allocator, param);
                if (!try self.match(.COMMA)) break;
            }
        }
        try self.consume(.RIGHT_PAREN, "Expected ')' to end coroutine parameters.");

        try self.consume(.ARROW, "Expected '->' to separate parameters from return type.");
        try self.consume(.LEFT_PAREN, "Expected '(' to start coroutine yield, return type.");
        const yield_type = try self.parse_type_expression();
        try self.consume(.COMMA, "Expected ',' to separate yield type from return type.");
        const return_type = try self.parse_type_expression();
        try self.consume(.RIGHT_PAREN, "Expected ')' to end coroutine yield, return type.");

        const body = try self.parse_statement();

        const co_decl = try self.allocator.create(AST.CoDecl);
        co_decl.* = .{
            .modifier_pub = is_pub,
            .name = name,
            .params = params.items,
            .modifier_static = is_static,
            .yield_type_annotation = yield_type,
            .return_type_annotation = return_type,
            .body = body,
            .line = name.line,
            .column = name.column,
        };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .co_decl = co_decl };
        return node;
    }

    fn parse_shape_expression(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_BRACE, "Expected '{' to start shape expression.");
        var fields: std.ArrayList(*AST.TypedNamedField) = .empty;
        if (!self.check(.RIGHT_BRACE)) {
            while (true) {
                const field = try self.parse_typed_named_field();
                try fields.append(self.allocator, field);
                if (self.check(.RIGHT_BRACE)) {
                    break;
                }
                try self.consume(.COMMA, "Expected ',' to separate shape fields.");
            }
        }
        try self.consume(.RIGHT_BRACE, "Expected '}' to end shape expression.");
        const shape_expr = try self.allocator.create(AST.ShapeExpr);
        shape_expr.* = .{ .fields = try fields.toOwnedSlice(self.allocator), .line = self.previous.line, .column = self.previous.column };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .shape_expr = shape_expr };
        return node;
    }

    fn parse_type_declaration(self: *Parser, is_pub: bool) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER, "Expected identifier for type declaration.");
        const name = self.previous;
        try self.consume(.EQUAL, "Expected '=' to start type annotation.");
        if (self.check(.LEFT_BRACE)) {
            const shape_expr = try self.parse_shape_expression();
            const type_decl = try self.allocator.create(AST.TypeDecl);
            type_decl.* = .{ .modifier_pub = is_pub, .name = name, .type_annotation = shape_expr, .line = name.line, .column = name.column };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .type_decl = type_decl };
            return node;
        } else {
            const type_expr = try self.parse_type_expression();
            const type_decl = try self.allocator.create(AST.TypeDecl);
            type_decl.* = .{ .modifier_pub = is_pub, .name = name, .type_annotation = type_expr, .line = name.line, .column = name.column };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .type_decl = type_decl };
            return node;
        }
        try self.workspace.diagnostics_mutex.lock(self.io);
        try self.workspace.diagnostics.add_diagnostic(.{ .column = self.scanner.column(), .line = self.scanner.line, .stage = .Parser, .severity = .Error, .message = "Unexpected token", .file_path = self.module.filepath });
        self.workspace.diagnostics_mutex.unlock(self.io);
        return ParserError.UnexpectedToken;
    }

    fn parse_for_statement(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_PAREN, "Expected '(' to start for statement.");
        try self.consume(.VAR, "Expected 'var' to declare iterator.");
        try self.consume(.IDENTIFIER, "Expected identifier for iterator name.");
        const iterator_name = self.previous; // the type of this is var will be int
        try self.consume(.IN, "Expected 'in' to start iterator expression.");
        // for now, assume the iterator expression is a range expression
        const range_expr = try self.parse_expression();
        try self.consume(.RIGHT_PAREN, "Expected ')' to end for statement.");
        const body = try self.parse_statement();
        const for_stmt = try self.allocator.create(AST.ForStmt);
        for_stmt.* = .{ .iterator_name = iterator_name, .iterator_expr = range_expr, .body = body, .line = iterator_name.line, .column = iterator_name.column };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .for_stmt = for_stmt };
        return node;
    }

    fn parse_while_statement(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_PAREN, "Expected '(' to start while statement condition.");
        const condition = try self.parse_expression();
        try self.consume(.RIGHT_PAREN, "Expected ')' to end while statement condition.");
        const body = try self.parse_statement();
        const while_stmt = try self.allocator.create(AST.WhileStmt);
        while_stmt.* = .{ .condition = condition, .body = body, .line = self.previous.line, .column = self.previous.column };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .while_stmt = while_stmt };
        return node;
    }

    fn parse_if_statement(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_PAREN, "Expected '(' to start if statement condition.");
        const condition = try self.parse_expression();
        try self.consume(.RIGHT_PAREN, "Expected ')' to end if statement condition.");
        const then_branch = try self.parse_statement();

        var else_branch: ?*AST.ASTNode = null;
        if (self.check(.ELSE)) {
            try self.consume(.ELSE, "Expected 'else' to start else branch.");
            else_branch = try self.parse_statement();
        }

        const if_stmt = try self.allocator.create(AST.IfStmt);
        if_stmt.* = .{ .condition = condition, .then_branch = then_branch, .else_branch = else_branch, .line = self.previous.line, .column = self.previous.column };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .if_stmt = if_stmt };
        return node;
    }

    fn parse_expression_statement(self: *Parser) ParserError!*AST.ASTNode {
        const expr = try self.parse_expression();
        try self.consume(.SEMICOLON, "Expected ';' to end expression statement.");
        const expr_stmt = try self.allocator.create(AST.ExprStmt);
        expr_stmt.* = .{ .expr = expr, .line = self.previous.line, .column = self.previous.column };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .expr_stmt = expr_stmt };
        return node;
    }

    fn parse_return_statement(self: *Parser) ParserError!*AST.ASTNode {
        if (self.check(.SEMICOLON)) {
            try self.consume(.SEMICOLON, "Expected ';' to end return statement.");
            const return_stmt = try self.allocator.create(AST.ReturnStmt);
            return_stmt.* = .{ .expr = null, .line = self.previous.line, .column = self.previous.column };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .return_stmt = return_stmt };
            return node;
        }

        const expr = try self.parse_expression();
        try self.consume(.SEMICOLON, "Expected ';' to end return statement.");
        const return_stmt = try self.allocator.create(AST.ReturnStmt);
        return_stmt.* = .{ .expr = expr, .line = self.previous.line, .column = self.previous.column };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .return_stmt = return_stmt };
        return node;
    }

    fn parse_break_statement(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.SEMICOLON, "Expected ';' to end break statement.");
        const break_stmt = try self.allocator.create(AST.BreakStmt);
        break_stmt.* = .{ .line = self.previous.line, .column = self.previous.column };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .break_stmt = break_stmt };
        return node;
    }

    fn parse_continue_statement(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.SEMICOLON, "Expected ';' to end continue statement.");
        const continue_stmt = try self.allocator.create(AST.ContinueStmt);
        continue_stmt.* = .{ .line = self.previous.line, .column = self.previous.column };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .continue_stmt = continue_stmt };
        return node;
    }

    fn parse_panic_statement(self: *Parser) ParserError!*AST.ASTNode {
        const expr = try self.parse_expression();
        try self.consume(.SEMICOLON, "Expected ';' to end panic statement.");
        const panic_stmt = try self.allocator.create(AST.PanicStmt);
        panic_stmt.* = .{ .expr = expr, .line = self.previous.line, .column = self.previous.column };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .panic_stmt = panic_stmt };
        return node;
    }

    fn parse_block_statement(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_BRACE, "Expected '{' to start block statement.");
        var statements: std.ArrayList(*AST.ASTNode) = .empty;
        while (!self.check(.RIGHT_BRACE) and !self.check(.EOF)) {
            const stmt = try self.parse_declaration();
            try statements.append(self.allocator, stmt);
        }

        try self.consume(.RIGHT_BRACE, "Expected '}' to end block statement.");

        const block = try self.allocator.create(AST.BlockStmt);
        block.* = .{ .stmts = try statements.toOwnedSlice(self.allocator), .line = self.previous.line, .column = self.previous.column };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .block_stmt = block };

        return node;
    }

    fn parse_match_case(self: *Parser) ParserError!*MatchCase {
        if (try self.match(.DEFAULT)) {
            try self.consume(.EQUAL_ARROW, "Expected '=>' to start default match case.");
            const stmt = try self.parse_statement();
            const pat = try self.allocator.create(AST.DefaultPat);
            pat.* = .{};
            const pat_node = try self.allocator.create(AST.ASTNode);
            pat_node.* = .{ .default_pat = pat };
            const case = try self.allocator.create(MatchCase);
            case.* = .{ .pattern = pat_node, .stmt = stmt, .line = self.previous.line, .column = self.previous.column };
            return case;
        }
        const expr = try self.parse_expression();
        try self.consume(.EQUAL_ARROW, "Expected '=>' to start match case.");
        const stmt = try self.parse_statement();
        const case = try self.allocator.create(MatchCase);
        case.* = .{ .pattern = expr, .stmt = stmt, .line = self.previous.line, .column = self.previous.column };
        return case;
    }

    fn parse_match_expression(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_PAREN, "Expected '(' to start match target expression.");
        const expr = try self.parse_expression();
        try self.consume(.RIGHT_PAREN, "Expected ')' to end match target expression.");
        try self.consume(.LEFT_BRACE, "Expected '{' to start match expression body.");
        var cases: std.ArrayList(*MatchCase) = .empty;
        while (!self.check(.RIGHT_BRACE) and !self.check(.EOF)) {
            const case = try self.parse_match_case();
            try cases.append(self.allocator, case);
            if (!self.check(.RIGHT_BRACE)) try self.consume(.COMMA, "Expected ',' to separate match cases.");
        }
        try self.consume(.RIGHT_BRACE, "Expected '}' to end match expression body.");

        const match_expr = try self.allocator.create(AST.MatchExpr);
        match_expr.* = .{ .expr = expr, .cases = try cases.toOwnedSlice(self.allocator), .line = self.previous.line, .column = self.previous.column };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .match_expr = match_expr };
        return node;
    }

    fn parse_give_statement(self: *Parser) ParserError!*AST.ASTNode {
        const expr = try self.parse_expression();
        try self.consume(.SEMICOLON, "Expected ';' to end give statement.");

        const give_stmt = try self.allocator.create(AST.GiveStmt);
        give_stmt.* = .{ .expr = expr, .line = self.previous.line, .column = self.previous.column };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .give_stmt = give_stmt };
        return node;
    }

    fn parse_yield_statement(self: *Parser) ParserError!*AST.ASTNode {
        const expr = try self.parse_expression();
        try self.consume(.SEMICOLON, "Expected ';' to end yield statement.");

        const yield_stmt = try self.allocator.create(AST.YieldStmt);
        yield_stmt.* = .{ .expr = expr, .line = self.previous.line, .column = self.previous.column };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .yield_stmt = yield_stmt };
        return node;
    }

    fn parse_resume_expression(self: *Parser) ParserError!*AST.ASTNode {
        const expr = try self.parse_expression();
        try self.consume(.SEMICOLON, "Expected ';' to end resume expression.");

        const resume_expr = try self.allocator.create(AST.ResumeExpr);
        resume_expr.* = .{ .expr = expr, .line = self.previous.line, .column = self.previous.column };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .resume_expr = resume_expr };
        return node;
    }

    fn parse_error_declaration(self: *Parser, is_pub: bool) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER, "Expected identifier for error declaration.");
        const token = self.previous;

        try self.consume(.LEFT_BRACE, "Expected '{' to start error declaration body.");
        var variants: std.ArrayList(Token) = .empty;
        while (!self.check(.RIGHT_BRACE) and !self.check(.EOF)) {
            try self.consume(.IDENTIFIER, "Expected identifier for error variant.");
            const variant = self.previous;
            try variants.append(self.allocator, variant);
            if (self.check(.RIGHT_BRACE)) {
                break;
            }
            try self.consume(.COMMA, "Expected ',' to separate error variants.");
        }
        try self.consume(.RIGHT_BRACE, "Expected '}' to end error declaration body.");

        const error_decl = try self.allocator.create(AST.ErrorDecl);
        error_decl.* = .{ .name = token, .variants = try variants.toOwnedSlice(self.allocator), .modifier_pub = is_pub, .line = token.line, .column = token.column };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .error_decl = error_decl };
        return node;
    }

    fn parse_enum_declaration(self: *Parser, is_pub: bool) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER, "Expected identifier for enum declaration.");
        const token = self.previous;

        try self.consume(.LEFT_BRACE, "Expected '{' to start enum declaration body.");
        var variants: std.ArrayList(Token) = .empty;
        while (!self.check(.RIGHT_BRACE) and !self.check(.EOF)) {
            try self.consume(.IDENTIFIER, "Expected identifier for enum variant.");
            const variant = self.previous;
            try variants.append(self.allocator, variant);
            if (self.check(.RIGHT_BRACE)) {
                break;
            }
            try self.consume(.COMMA, "Expected ',' to separate enum variants.");
        }
        try self.consume(.RIGHT_BRACE, "Expected '}' to end enum declaration body.");

        const enum_decl = try self.allocator.create(AST.EnumDecl);
        enum_decl.* = .{ .name = token, .variants = try variants.toOwnedSlice(self.allocator), .modifier_pub = is_pub, .line = token.line, .column = token.column };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .enum_decl = enum_decl };
        return node;
    }

    fn parse_struct_declaration(self: *Parser, is_pub: bool) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER, "Expected identifier for struct declaration.");
        const name = self.previous;
        try self.consume(.LEFT_BRACE, "Expected '{' to start struct declaration body.");
        var fields: std.ArrayList(*AST.TypedNamedStructField) = .empty;
        var methods: std.ArrayList(*AST.StructMethodField) = .empty;

        while (!self.check(.RIGHT_BRACE) and !self.check(.EOF)) {
            var is_static = false;
            var is_public = false;

            if (try self.match(.PUB)) {
                is_public = true;
            }

            if (try self.match(.STATIC)) {
                is_static = true;
            }

            if (is_public and is_static) {
                try self.workspace.diagnostics_mutex.lock(self.io);
                try self.workspace.diagnostics.add_diagnostic(.{ .column = self.scanner.column(), .line = self.scanner.line, .stage = .Parser, .severity = .Error, .message = "'pub static' / 'static pub' is not allowed. Use 'static' or 'pub' alone instead.", .file_path = self.module.filepath });
                self.workspace.diagnostics_mutex.unlock(self.io);
                return ParserError.UnexpectedToken; // 'pub static' / 'static pub' is not allowed
            }

            if (try self.match(.CO)) {
                const method = try self.parse_coroutine_declaration(is_public, is_static);
                const struct_method = try self.allocator.create(AST.StructMethodField);
                struct_method.* = .{ .is_static = is_static, .method = method, .is_pub = is_public, .name = method.co_decl.name };
                try methods.append(self.allocator, struct_method);
                _ = try self.match(.COMMA);
                continue;
            }
            if (try self.match(.FN)) {
                const method = try self.parse_function_declaration(is_public, is_static);
                const struct_method = try self.allocator.create(AST.StructMethodField);
                struct_method.* = .{ .is_static = is_static, .method = method, .is_pub = is_public, .name = method.fn_decl.name };
                try methods.append(self.allocator, struct_method);
                _ = try self.match(.COMMA);
                continue;
            }

            const field = try self.parse_struct_field(is_public, is_static);
            try fields.append(self.allocator, field);
            if (self.check(.RIGHT_BRACE)) {
                break;
            }
            try self.consume(.COMMA, "Expected ',' to separate struct fields.");
        }
        try self.consume(.RIGHT_BRACE, "Expected '}' to end struct declaration body.");
        const struct_decl = try self.allocator.create(AST.StructDecl);

        if (is_pub) {}

        struct_decl.* = .{
            .modifier_pub = is_pub,
            .name = name,
            .fields = try fields.toOwnedSlice(self.allocator),
            .methods = try methods.toOwnedSlice(self.allocator),
            .line = name.line,
            .column = name.column,
        };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{
            .struct_decl = struct_decl,
        };
        return node;
    }

    fn parse_use_declaration(self: *Parser, is_pub: bool) ParserError!*AST.ASTNode {
        var items: std.ArrayList(AST.ImportItem) = .empty;

        while (true) {
            try self.consume(.IDENTIFIER, "Expected identifier for import item.");
            const name = self.previous;

            var alias: ?Token = null;
            if (try self.match(.AS)) {
                try self.consume(.IDENTIFIER, "Expected identifier for alias.");
                alias = self.previous;
            }

            try items.append(self.allocator, AST.ImportItem{ .name = name, .alias = alias });

            if (try self.match(.FROM)) break;
            try self.consume(.COMMA, "Expected ',' to separate import items.");
        }

        try self.consume(.STRING, "Expected string for module path.");
        const module = self.previous;
        try self.consume(.SEMICOLON, "Expected ';' to end import statement.");

        const workspace_resolved_module_path = try self.workspace.resolve_path(self.module.filepath, module.lexeme[1 .. module.lexeme.len - 1]);
        const parser_resolved_module_path = try self.allocator.dupe(u8, workspace_resolved_module_path);
        self.workspace.allocator.free(workspace_resolved_module_path);

        const use_decl = try self.allocator.create(AST.UseDecl);
        use_decl.* = .{ .items = try items.toOwnedSlice(self.allocator), .module = module, .line = module.line, .column = module.column, .modifier_pub = is_pub, .resolved_module_path = parser_resolved_module_path };

        // add the module to the workspace
        self.workspace.submit_import(self.group, self.module.filepath, module.lexeme[1 .. module.lexeme.len - 1]) catch |err| {
            try self.workspace.diagnostics_mutex.lock(self.io);
            try self.workspace.diagnostics.add_diagnostic(.{
                .file_path = self.module.filepath,
                .column = module.column,
                .line = module.line,
                .stage = .Parser,
                .severity = .Error,
                .message = "Could not load module",
                .hint = @errorName(err),
            });
            self.workspace.diagnostics_mutex.unlock(self.io);
        };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .use_decl = use_decl };
        return node;
    }

    fn parse_expression(self: *Parser) ParserError!*AST.ASTNode {
        return try self.parse_assignment();
    }

    fn is_table_literal_lookahead(self: *Parser) bool {
        var idx = self.scanner.current;
        // Skip whitespace and comments
        while (idx < self.scanner.source.len) {
            const c = self.scanner.source[idx];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                idx += 1;
            } else if (c == '/' and idx + 1 < self.scanner.source.len and self.scanner.source[idx + 1] == '/') {
                // Skip comment
                idx += 2;
                while (idx < self.scanner.source.len and self.scanner.source[idx] != '\n') {
                    idx += 1;
                }
            } else {
                break;
            }
        }
        if (idx >= self.scanner.source.len) return false;

        const quote = self.scanner.source[idx];
        if (quote != '"' and quote != '\'') return false;
        idx += 1;

        // Find matching quote
        var escaped = false;
        while (idx < self.scanner.source.len) {
            if (idx >= self.scanner.source.len) break;
            const c = self.scanner.source[idx];
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == quote) {
                idx += 1;
                break;
            }
            idx += 1;
        }

        // Skip whitespace and comments again
        while (idx < self.scanner.source.len) {
            const c = self.scanner.source[idx];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                idx += 1;
            } else if (c == '/' and idx + 1 < self.scanner.source.len and self.scanner.source[idx + 1] == '/') {
                idx += 2;
                while (idx < self.scanner.source.len and self.scanner.source[idx] != '\n') {
                    idx += 1;
                }
            } else {
                break;
            }
        }

        if (idx < self.scanner.source.len and self.scanner.source[idx] == ':') {
            return true;
        }
        return false;
    }

    fn parse_statement(self: *Parser) ParserError!*AST.ASTNode {
        if (try self.match(.IF)) {
            return try self.parse_if_statement();
        } else if (self.check(.LEFT_BRACE)) {
            if (self.is_table_literal_lookahead()) {
                return try self.parse_expression_statement();
            }
            return try self.parse_block_statement();
        } else if (try self.match(.FOR)) {
            return try self.parse_for_statement();
        } else if (try self.match(.WHILE)) {
            return try self.parse_while_statement();
        } else if (try self.match(.RETURN)) {
            return try self.parse_return_statement();
        } else if (try self.match(.YIELD)) {
            return try self.parse_yield_statement();
        } else if (try self.match(.GIVE)) {
            return try self.parse_give_statement();
        } else if (try self.match(.BREAK)) {
            return try self.parse_break_statement();
        } else if (try self.match(.CONTINUE)) {
            return try self.parse_continue_statement();
        } else if (try self.match(.PANIC)) {
            return try self.parse_panic_statement();
        } else {
            return try self.parse_expression_statement();
        }
    }

    fn parse_declaration(self: *Parser) ParserError!*AST.ASTNode {
        var is_pub = false;
        if (try self.match(.PUB)) {
            is_pub = true;
        }

        if (try self.match(.VAR)) {
            return try self.parse_var_declaration(is_pub);
        } else if (try self.match(.FN)) {
            return try self.parse_function_declaration(is_pub, false);
        } else if (try self.match(.CO)) {
            return try self.parse_coroutine_declaration(is_pub, false);
        } else if (try self.match(.STRUCT)) {
            return try self.parse_struct_declaration(is_pub);
        } else if (try self.match(.TYPE)) {
            return try self.parse_type_declaration(is_pub);
        } else if (try self.match(.ENUM)) {
            return try self.parse_enum_declaration(is_pub);
        } else if (try self.match(.ERROR)) {
            return try self.parse_error_declaration(is_pub);
        } else if (try self.match(.USE)) {
            return try self.parse_use_declaration(is_pub);
        } else {
            if (is_pub) {
                try self.workspace.diagnostics_mutex.lock(self.io);
                try self.workspace.diagnostics.add_diagnostic(.{ .column = self.scanner.column(), .file_path = self.module.filepath, .line = self.scanner.line, .stage = .Parser, .severity = .Error, .message = "Unexpected token", .hint = "'pub' is only allowed inside struct and for top level declarations." });
                self.workspace.diagnostics_mutex.unlock(self.io);
                return ParserError.UnexpectedToken;
            }
            return try self.parse_statement();
        }
    }

    pub fn parse(self: *Parser) ParserError!*AST.ASTNode {
        const program = try self.allocator.create(AST.Program);
        var declarations: std.ArrayList(*AST.ASTNode) = .empty;
        while (!self.check(.EOF)) {
            try declarations.append(self.allocator, try self.parse_declaration());
        }
        program.* = .{ .declarations = try declarations.toOwnedSlice(self.allocator) };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .program = program };
        return node;
    }
};
