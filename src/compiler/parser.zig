const AST = @import("ast.zig");
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("scanner.zig").Token;
const TokenType = @import("scanner.zig").TokenType;
const MatchCase = AST.MatchCase;

const std = @import("std");

pub const ParserError = error{
    UnexpectedToken,
};

pub const Parser = struct {
    scanner: *Scanner,
    allocator: std.mem.Allocator,
    current: Token,
    previous: Token,

    pub fn init(allocator: std.mem.Allocator, scanner: *Scanner) !Parser {
        var parser = Parser{
            .allocator = allocator,
            .scanner = scanner,
            .current = Token{},
            .previous = Token{},
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

    fn consume(self: *Parser, expected: TokenType) ParserError!void {
        if (self.current.token_type == expected) {
            try self.advance();
            return;
        }
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

        if (self.check(.EQUAL) or self.check(.PLUS_EQUAL) or self.check(.MINUS_EQUAL) or self.check(.STAR_EQUAL) or self.check(.SLASH_EQUAL)) {
            const operator = self.current;
            try self.advance();

            const right = try self.parse_assignment();

            const assign = try self.allocator.create(AST.AssignExpr);
            assign.* = .{
                .left = left,
                .operator = operator,
                .right = right,
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
            binary.* = .{ .operator = operator, .left = left, .right = right };
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
        while (self.check(.EQUAL) or self.check(.NOT_EQUAL)) {
            const operator = self.current;
            try self.advance();
            const right = try self.parse_comparison();
            const binary = try self.allocator.create(AST.BinaryExpr);
            binary.* = .{
                .operator = operator,
                .left = left,
                .right = right,
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
        while (self.check(.PLUS) or self.check(.MINUS)) {
            const operator = self.current;
            try self.advance();
            const right = try self.parse_factor();

            const binary = try self.allocator.create(AST.BinaryExpr);
            binary.* = .{
                .operator = operator,
                .left = left,
                .right = right,
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
        while (self.check(.STAR) or self.check(.PERCENT) or self.check(.SLASH)) {
            const operator = self.current;
            try self.advance();
            const right = try self.parse_unary();

            const binary = try self.allocator.create(AST.BinaryExpr);
            binary.* = .{
                .operator = operator,
                .left = left,
                .right = right,
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
        if (self.check(.TILDE) or self.check(.MINUS) or self.check(.NOT)) {
            const operator = self.current;
            try self.advance();
            // chaining unaries
            const right = try self.parse_unary();

            const unary = try self.allocator.create(AST.UnaryExpr);
            unary.* = .{ .operator = operator, .expr = right };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .unary_expr = unary };
            return node;
        }
        // if no unary go to next precedence
        return try self.parse_cast();
    }

    fn parse_cast(self: *Parser) ParserError!*AST.ASTNode {
        var expr = try self.parse_postfix();

        while (try self.match(.AS)) {
            const type_node = try self.parse_type_expression();

            const cast = try self.allocator.create(AST.CastExpr);
            cast.* = .{ .expr = expr, .type = type_node };

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
                var args = std.ArrayList(*AST.ASTNode).init(self.allocator);
                if (!self.check(.RIGHT_PAREN)) {
                    while (true) {
                        try args.append(try self.parse_expression());
                        if (!try self.match(.COMMA)) break;
                    }
                }
                try self.consume(.RIGHT_PAREN);

                const call = try self.allocator.create(AST.CallExpr);
                call.* = .{ .expr = expr, .args = try args.toOwnedSlice() };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .call_expr = call };
                expr = node;
            } else if (try self.match(.LEFT_SQUARE)) {
                // Index
                const index = try self.parse_expression();
                try self.consume(.RIGHT_SQUARE);

                const index_expr = try self.allocator.create(AST.IndexExpr);
                index_expr.* = .{ .expr = expr, .index = index };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .index_expr = index_expr };
                expr = node;
            } else if (try self.match(.DOT)) {
                // Instance Member
                try self.consume(.IDENTIFIER);
                const member = self.previous;

                const inst_expr = try self.allocator.create(AST.InstanceMemberExpr);
                inst_expr.* = .{ .expr = expr, .member = member };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .instance_member_expr = inst_expr };
                expr = node;
            } else if (try self.match(.COLON_COLON)) {
                // Static Member
                try self.consume(.IDENTIFIER);
                const member = self.previous;

                const static_expr = try self.allocator.create(AST.StaticMemberExpr);
                static_expr.* = .{ .expr = expr, .member = member };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .static_member_expr = static_expr };
                expr = node;
            } else if (try self.match(.QUESTION_MARK)) {
                // Unwrap Error
                const unwrap = try self.allocator.create(AST.ErrorUnwrapExpr);
                unwrap.* = .{ .expr = expr };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .error_unwrap_expr = unwrap };
                expr = node;
            } else {
                break;
            }
        }
        return expr;
    }

    fn parse_primary(self: *Parser) ParserError!*AST.ASTNode {
        if (try self.match(.CO)) {
            if (try self.match(.FN)) {
                return try self.parse_anonymous_function(true);
            }
        } else if (try self.match(.FN)) {
            return try self.parse_anonymous_function(false);
        } else if (try self.match(.TRUE) or try self.match(.FALSE) or try self.match(.STRING) or try self.match(.INT) or try self.match(.FLOAT) or try self.match(.NIL)) {
            return try self.parse_literal();
        } else if (try self.match(.IDENTIFIER)) {
            return try self.parse_identifier_expression();
        } else if (try self.match(.LEFT_SQUARE)) {
            return try self.parse_array_literal();
        } else if (try self.match(.LEFT_BRACE)) {
            return try self.parse_table_literal();
        } else if (try self.match(.LEFT_PAREN)) {
            return try self.parse_group_or_tuple();
        } else if (try self.match(.NEW)) {
            return try self.parse_new_expression();
        } else if (try self.match(.MATCH)) {
            return try self.parse_match_expression();
        } else {
            return ParserError.UnexpectedToken;
        }
    }

    fn parse_literal(self: *Parser) ParserError!*AST.ASTNode {
        const token = self.current;
        switch (token.token_type) {
            TokenType.STRING => {
                try self.advance();
                const literal = try self.allocator.create(AST.StrLit);
                literal.* = .{ .value = token.lexeme };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .str_lit = literal };
                return node;
            },
            TokenType.INT => {
                try self.advance();
                const literal = try self.allocator.create(AST.IntLit);
                literal.* = .{ .value = std.fmt.parseInt(i64, token.lexeme, 10) };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .int_lit = literal };
                return node;
            },
            TokenType.FLOAT => {
                try self.advance();
                const literal = try self.allocator.create(AST.FloatLit);
                literal.* = .{ .value = std.fmt.parseFloat(f64, token.lexeme, 10) };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .float_lit = literal };
                return node;
            },
            TokenType.TRUE => {
                try self.advance();
                const literal = try self.allocator.create(AST.BoolLit);
                literal.* = .{ .value = true };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .bool_lit = literal };
                return node;
            },
            TokenType.FALSE => {
                try self.advance();
                const literal = try self.allocator.create(AST.BoolLit);
                literal.* = .{ .value = false };
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .bool_lit = literal };
                return node;
            },
            TokenType.NIL => {
                try self.advance();
                const literal = try self.allocator.create(AST.NilLit);
                const node = try self.allocator.create(AST.ASTNode);
                node.* = .{ .nil_lit = literal };
                return node;
            },
            else => {
                return ParserError.UnexpectedToken;
            },
        }
    }

    fn parse_group_or_tuple(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_PAREN);

        // Empty tuple: ()
        if (try self.match(.RIGHT_PAREN)) {
            const empty_tuple = try self.allocator.create(AST.TupleExpr);
            empty_tuple.* = .{ .exprs = &[_]*AST.ASTNode{} };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .tuple_expr = empty_tuple };
            return node;
        }

        const first_expr = try self.parse_expression();

        if (try self.match(.COMMA)) {
            // It's a tuple: (expr,) or (expr, expr)
            var elements = std.ArrayList(*AST.ASTNode).init(self.allocator);
            try elements.append(first_expr);

            if (!self.check(.RIGHT_PAREN)) {
                while (true) {
                    try elements.append(try self.parse_expression());
                    if (!try self.match(.COMMA)) break;
                }
            }
            try self.consume(.RIGHT_PAREN);

            const tuple_expr = try self.allocator.create(AST.TupleExpr);
            tuple_expr.* = .{ .exprs = try elements.toOwnedSlice(), .resolved_type = 0 };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .tuple_expr = tuple_expr };
            return node;
        } else {
            // It's a group: (expr)
            try self.consume(.RIGHT_PAREN);
            const group = try self.allocator.create(AST.GroupExpr);
            group.* = .{ .expr = first_expr, .resolved_type = 0 };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .group_expr = group };
            return node;
        }
    }

    fn parse_new_expression(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER);
        const struct_name = self.previous;

        try self.consume(.LEFT_BRACE);
        var fields = std.ArrayList(AST.StructInitField).init(self.allocator);

        if (!self.check(.RIGHT_BRACE)) {
            while (true) {
                try self.consume(.IDENTIFIER);
                const field_name = self.previous;
                try self.consume(.EQUAL);
                const value = try self.parse_expression();

                try fields.append(AST.StructInitField{ .name = field_name, .value = value });

                if (!try self.match(.COMMA)) break;
            }
        }
        try self.consume(.RIGHT_BRACE);

        const new_expr = try self.allocator.create(AST.NewExpr);
        new_expr.* = .{ .struct_name = struct_name, .fields = try fields.toOwnedSlice(), .resolved_type = 0 };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .new_expr = new_expr };
        return node;
    }

    fn parse_identifier_expression(self: *Parser) ParserError!*AST.ASTNode {
        self.consume(.IDENTIFIER);
        const token = self.previous;
        const identifier = try self.allocator.create(AST.IdentifierExpr);
        identifier.* = .{ .name = token };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .identifier_expr = identifier };
        return node;
    }

    fn parse_anonymous_function(self: *Parser, is_coroutine: bool) ParserError!*AST.ASTNode {
        try self.advance();

        try self.consume(.LEFT_PAREN);
        var params = std.ArrayList(*AST.TypedNamedField).init(self.allocator);

        if (!self.check(.RIGHT_PAREN)) {
            while (true) {
                const param_node = try self.parse_typed_named_field(); // Helper to parse "name: Type"
                try params.append(param_node);
                if (!try self.match(.COMMA)) break;
            }
        }
        try self.consume(.RIGHT_PAREN);

        var return_type: ?*AST.ASTNode = null;
        if (try self.match(.ARROW)) {
            return_type = try self.parse_type_expr();
        }

        const body = try self.parse_statement();

        const anon = try self.allocator.create(AST.AnonFnExpr);
        anon.* = .{
            .modifier_co = is_coroutine,
            .params = try params.toOwnedSlice(),
            .return_type_annotation = return_type,
            .body = body,
        };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .anon_fn_expr = anon };
        return node;
    }

    fn parse_typed_named_field(self: *Parser) ParserError!*AST.TypedNamedField {
        try self.consume(.IDENTIFIER);
        const token = self.previous;
        try self.consume(.COLON);
        const type_ = self.parse_type_expression();
        const named_field = self.allocator.create(AST.TypedNamedField);
        named_field.* = .{ .name = token, .type_annotation = type_ };
        return named_field;
    }

    fn parse_type_expression(self: *Parser) ParserError!*AST.ASTNode {
        var left: *AST.ASTNode = undefined;

        if (try self.match(.SHAPE)) {
            left = try self.parse_shape_expression();
        } else if (try self.match(.FN)) {
            // Function Type: fn (Int, Float) -> Bool
            try self.consume(.LEFT_PAREN);
            var params = std.ArrayList(*AST.ASTNode).init(self.allocator);
            if (!self.check(.RIGHT_PAREN)) {
                while (true) {
                    try params.append(try self.parse_type_expression());
                    if (!try self.match(.COMMA)) break;
                }
            }
            try self.consume(.RIGHT_PAREN);

            var return_type: ?*AST.ASTNode = null;
            if (try self.match(.ARROW)) {
                return_type = try self.parse_type_expression();
            }

            const fn_type = try self.allocator.create(AST.FnType);
            fn_type.* = .{ .params = try params.toOwnedSlice(), .return_type = return_type };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .fn_type = fn_type };
            left = node;
        } else if (try self.match(.LEFT_PAREN)) {
            // Tuple type: (Int, Float)
            var elements = std.ArrayList(*AST.ASTNode).init(self.allocator);
            if (!self.check(.RIGHT_PAREN)) {
                while (true) {
                    try elements.append(try self.parse_type_expression());
                    if (!try self.match(.COMMA)) break;
                }
            }
            try self.consume(.RIGHT_PAREN);

            const tuple_type = try self.allocator.create(AST.TupleType);
            tuple_type.* = .{ .element_types = try elements.toOwnedSlice() };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .tuple_type = tuple_type };
            left = node;
        } else {
            // Identifiers and Generics: Array[Int]
            try self.consume(.IDENTIFIER);
            const name = self.previous;

            var generic_args: ?[]*AST.ASTNode = null;
            if (try self.match(.LEFT_SQUARE)) {
                var args = std.ArrayList(*AST.ASTNode).init(self.allocator);
                while (true) {
                    try args.append(try self.parse_type_expression());
                    if (!try self.match(.COMMA)) break;
                }
                try self.consume(.RIGHT_SQUARE);
                generic_args = try args.toOwnedSlice();
            }

            const id_type = try self.allocator.create(AST.IdentifierType);
            id_type.* = .{ .name = name, .generic_args = generic_args };
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
        const key_types = std.ArrayList(*AST.ASTNode).init(self.allocator);
        const value_types = std.ArrayList(*AST.ASTNode).init(self.allocator);

        while (true) {
            const key_type = try self.parse_expression();
            try self.consume(.COLON);
            const value_type = try self.parse_expression();
            try key_types.append(key_type);
            try value_types.append(value_type);
            if (self.check(.RIGHT_BRACE)) {
                break;
            }
            try self.consume(.COMMA);
        }
        try self.consume(.RIGHT_BRACE);

        const table_literal = try self.allocator.create(AST.TableExpr);
        table_literal.* = .{
            .keys = key_types.toOwnedSlice(),
            .values = value_types.toOwnedSlice(),
        };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .table_expr = table_literal };

        return node;
    }

    fn parse_array_literal(self: *Parser) ParserError!*AST.ASTNode {
        var elements = std.ArrayList(*AST.ASTNode).init(self.allocator);
        while (true) {
            const element = try self.parse_expression();
            try elements.append(element);
            if (self.check(.RIGHT_SQUARE)) {
                break;
            }
            try self.consume(.COMMA);
        }
        try self.consume(.RIGHT_SQUARE);

        const array_literal = try self.allocator.create(AST.ArrayExpr);
        array_literal.* = .{
            .elements = elements.toOwnedSlice(),
        };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .array_expr = array_literal };

        return node;
    }

    fn parse_var_declaration(self: *Parser, is_pub: bool) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER);
        const name = self.previous;

        var type_annotation: ?*AST.ASTNode = null;
        if (try self.match(.COLON)) {
            type_annotation = try self.parse_type_expression();
        }

        try self.consume(.EQUAL);
        const initializer = try self.parse_expression();
        try self.consume(.SEMICOLON);

        const var_decl = try self.allocator.create(AST.VarDecl);
        var_decl.* = .{
            .modifier_pub = is_pub,
            .name = name,
            .type_annotation = type_annotation,
            .initializer = initializer,
        };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .var_decl = var_decl };

        return node;
    }

    fn parse_function_declaration(self: *Parser, is_pub: bool, is_static: bool, is_co: bool) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER);
        const name = self.previous;

        try self.consume(.LEFT_PAREN);
        var params = std.ArrayList(*AST.TypedNamedField).init(self.allocator);

        if (!self.check(.RIGHT_PAREN)) {
            while (true) {
                const param = try self.parse_typed_named_field();
                try params.append(param);
                if (!try self.match(.COMMA)) break;
            }
        }
        try self.consume(.RIGHT_PAREN);

        // Optional return type
        var return_type: ?*AST.ASTNode = null;
        if (try self.match(.ARROW)) {
            return_type = try self.parse_type_expression();
        }

        const body = try self.parse_statement();

        const fn_decl = try self.allocator.create(AST.FnDecl);
        fn_decl.* = .{
            .modifier_pub = is_pub,
            .modifier_static = is_static,
            .modifier_co = is_co,
            .name = name,
            .params = try params.toOwnedSlice(),
            .return_type_annotation = return_type,
            .body = body,
        };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .fn_decl = fn_decl };

        return node;
    }

    fn parse_shape_expression(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_BRACE);
        const fields = std.ArrayList(*AST.TypedNamedField).init(self.allocator);
        while (!self.check(.RIGHT_BRACE) and !self.check(.EOF)) {
            const field = try self.parse_typed_named_field();
            try fields.append(field);
        }
        try self.consume(.RIGHT_BRACE);
        const shape_expr = try self.allocator.create(AST.ShapeExpr);
        shape_expr.* = .{ .fields = try fields.toOwnedSlice() };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .shape_expr = shape_expr };
        return node;
    }

    fn parse_type_declaration(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER);
        const name = self.previous;
        try self.consume(.EQUAL);
        if (self.check(.LEFT_BRACE)) {
            const shape_expr = try self.parse_shape_expression();
            const type_decl = try self.allocator.create(AST.TypeDecl);
            type_decl.* = .{ .name = name, .shape_expr = shape_expr };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .type_decl = type_decl };
            return node;
        } else {
            const type_expr = try self.parse_type_expression();
            const type_decl = try self.allocator.create(AST.TypeDecl);
            type_decl.* = .{ .name = name, .type_annotation = type_expr };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .type_decl = type_decl };
            return node;
        }
        return ParserError.UnexpectedToken;
    }

    fn parse_impl_declaration(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER);
        const name = self.previous;
        var is_static = false;
        var is_coroutine = false;
        try self.consume(.LEFT_BRACE);
        const methods = std.ArrayList(*AST.ASTNode).init(self.allocator);

        while (!self.check(.RIGHT_BRACE) and !self.check(.EOF)) {
            if (self.check(.STATIC)) {
                try self.consume(.STATIC);
                is_static = true;
            } else {
                is_static = false;
            }
            if (self.check(.COROUTINE)) {
                try self.consume(.COROUTINE);
                is_coroutine = true;
            } else {
                is_coroutine = false;
            }
            try self.consume(.FN);
            const fn_decl = try self.parse_function_declaration(false, is_static, is_coroutine);
            try methods.append(fn_decl);
        }
        try self.consume(.RIGHT_BRACE);

        const impl_decl = try self.allocator.create(AST.ImplDecl);
        impl_decl.* = .{ .name = name, .methods = try methods.toOwnedSlice() };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .impl_decl = impl_decl };
        return node;
    }

    fn parse_for_statement(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_PAREN);
        try self.consume(.IDENTIFIER);
        const iterator_name = self.previous;
        try self.consume(.IN);
        const iterator_expr = try self.parse_expression();
        try self.consume(.RIGHT_PAREN);
        const body = try self.parse_block_statement();
        const for_stmt = try self.allocator.create(AST.ForStmt);
        for_stmt.* = .{ .iterator_name = iterator_name, .iterator_expr = iterator_expr, .body = body };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .for_stmt = for_stmt };
        return node;
    }

    fn parse_while_statement(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_PAREN);
        const condition = try self.parse_expression();
        try self.consume(.RIGHT_PAREN);
        const body = try self.parse_statement();
        const while_stmt = try self.allocator.create(AST.WhileStmt);
        while_stmt.* = .{ .condition = condition, .body = body };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .while_stmt = while_stmt };
        return node;
    }

    fn parse_if_statement(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_PAREN);
        const condition = try self.parse_expression();
        try self.consume(.RIGHT_PAREN);
        const then_branch = try self.parse_statement();

        var else_branch: *AST.ASTNode = null;
        if (self.check(.ELSE)) {
            try self.consume(.ELSE);
            else_branch = try self.parse_statement();
        }

        const if_stmt = try self.allocator.create(AST.IfStmt);
        if_stmt.* = .{ .condition = condition, .then_branch = then_branch, .else_branch = else_branch };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .if_stmt = if_stmt };
        return node;
    }

    fn parse_expression_statement(self: *Parser) ParserError!*AST.ASTNode {
        const expr = try self.parse_expression();
        try self.consume(.SEMICOLON);
        const expr_stmt = try self.allocator.create(AST.ExprStmt);
        expr_stmt.* = .{ .expr = expr };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .expr_stmt = expr_stmt };
        return node;
    }

    fn parse_return_statement(self: *Parser) ParserError!*AST.ASTNode {
        if (self.check(.SEMICOLON)) {
            try self.consume(.SEMICOLON);
            const return_stmt = try self.allocator.create(AST.ReturnStmt);
            return_stmt.* = .{ .expr = null };
            const node = try self.allocator.create(AST.ASTNode);
            node.* = .{ .return_stmt = return_stmt };
            return node;
        }

        const expr = try self.parse_expression();
        try self.consume(.SEMICOLON);
        const return_stmt = try self.allocator.create(AST.ReturnStmt);
        return_stmt.* = .{ .expr = expr };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .return_stmt = return_stmt };
        return node;
    }

    fn parse_break_statement(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.SEMICOLON);
        const break_stmt = try self.allocator.create(AST.BreakStmt);
        break_stmt.* = .{};
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .break_stmt = break_stmt };
        return node;
    }

    fn parse_continue_statement(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.SEMICOLON);
        const continue_stmt = try self.allocator.create(AST.ContinueStmt);
        continue_stmt.* = .{};
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .continue_stmt = continue_stmt };
        return node;
    }

    fn parse_panic_statement(self: *Parser) ParserError!*AST.ASTNode {
        const expr = try self.parse_expression();
        try self.consume(.SEMICOLON);
        const panic_stmt = try self.allocator.create(AST.PanicStmt);
        panic_stmt.* = .{ .expr = expr };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .panic_stmt = panic_stmt };
        return node;
    }

    fn parse_block_statement(self: *Parser) ParserError!*AST.ASTNode {
        var statements = std.ArrayList(*AST.ASTNode).init(self.allocator);
        while (!self.check(.RIGHT_BRACE) and !self.check(.EOF)) {
            const stmt = try self.parse_declaration();
            try statements.append(stmt);
        }

        try self.consume(.RIGHT_BRACE);

        const block = try self.allocator.create(AST.BlockStmt);
        block.* = .{ .stmts = try statements.toOwnedSlice() };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .block_stmt = block };

        return node;
    }

    fn parse_match_case(self: *Parser) ParserError!*MatchCase {
        const expr = try self.parse_expression();
        try self.consume(.EQUAL_ARROW);
        const stmt = try self.parse_statement();
        const case = try self.allocator.create(MatchCase);
        case.* = .{ .expr = expr, .stmt = stmt };
        return case;
    }

    fn parse_match_expression(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.LEFT_PAREN);
        const expr = try self.parse_expression();
        try self.consume(.RIGHT_PAREN);
        try self.consume(.LEFT_BRACE);
        const cases = std.ArrayList(*MatchCase).init(self.allocator);
        while (!self.check(.RIGHT_BRACE) and !self.check(.EOF)) {
            const case = try self.parse_match_case();
            try cases.append(case);
            if (!self.check(.RIGHT_BRACE)) try self.consume(.COMMA);
        }
        try self.consume(.RIGHT_BRACE);

        const match_expr = try self.allocator.create(AST.MatchExpr);
        match_expr.* = .{ .expr = expr, .cases = cases };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .match_expr = match_expr };
        return node;
    }

    fn parse_give_statement(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.GIVE);
        const expr = try self.parse_expression();
        try self.consume(.SEMICOLON);

        const give_stmt = try self.allocator.create(AST.GiveStmt);
        give_stmt.* = .{ .expr = expr };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .give_stmt = give_stmt };
        return node;
    }

    fn parse_yield_statement(self: *Parser) ParserError!*AST.ASTNode {
        try self.consume(.YIELD);
        const expr = try self.parse_expression();
        try self.consume(.SEMICOLON);

        const yield_stmt = try self.allocator.create(AST.YieldStmt);
        yield_stmt.* = .{ .expr = expr };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .yield_stmt = yield_stmt };
        return node;
    }

    fn parse_error_declaration(self: *Parser, is_pub: bool) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER);
        const token = self.previous;

        try self.consume(.LEFT_BRACE);
        var variants = std.ArrayList(Token).init(self.allocator);
        while (true) {
            try self.consume(.IDENTIFIER);
            const variant = self.previous;
            try variants.append(variant);
            if (self.check(.RIGHT_BRACE)) {
                break;
            }
            try self.consume(.COMMA);
        }

        const error_decl = try self.allocator.create(AST.ErrorDecl);
        error_decl.* = .{ .name = token, .variants = variants.toOwnedSlice(), .modifier_pub = is_pub };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .error_decl = error_decl };
        return node;
    }

    fn parse_enum_declaration(self: *Parser, is_pub: bool) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER);
        const token = self.previous;

        try self.consume(.LEFT_BRACE);
        var variants = std.ArrayList(Token).init(self.allocator);
        while (true) {
            try self.consume(.IDENTIFIER);
            const variant = self.previous;
            try variants.append(variant);
            if (self.check(.RIGHT_BRACE)) {
                break;
            }
            try self.consume(.COMMA);
        }

        const enum_decl = try self.allocator.create(AST.EnumDecl);
        enum_decl.* = .{ .name = token, .variants = variants.toOwnedSlice(), .modifier_pub = is_pub };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .enum_decl = enum_decl };
        return node;
    }

    fn parse_struct_declaration(self: *Parser, is_pub: bool) ParserError!*AST.ASTNode {
        try self.consume(.IDENTIFIER);
        try self.consume(.LEFT_BRACE);
        var fields = std.ArrayList(*AST.ASTNode).init(self.allocator);
        while (true) {
            const field = try self.parse_typed_named_field();
            try fields.append(field);
            if (self.check(.RIGHT_BRACE)) {
                break;
            }
            try self.consume(.COMMA);
        }
        try self.consume(.RIGHT_BRACE);
        const struct_decl = try self.allocator.create(AST.StructDecl);
        struct_decl.* = .{
            .modifier_pub = is_pub,
            .fields = try fields.toOwnedSlice(),
        };
        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{
            .struct_decl = struct_decl,
        };
        return node;
    }

    fn parse_use_statement(self: *Parser) ParserError!*AST.ASTNode {
        var items = std.ArrayList(AST.ImportItem).init(self.allocator);

        while (true) {
            try self.consume(.IDENTIFIER);
            const name = self.previous;

            var alias: ?Token = null;
            if (try self.match(.AS)) {
                try self.consume(.IDENTIFIER);
                alias = self.previous;
            }

            try items.append(AST.ImportItem{ .name = name, .alias = alias });

            if (try self.match(.FROM)) break;
            try self.consume(.COMMA);
        }

        try self.consume(.STRING);
        const module = self.previous;
        try self.consume(.SEMICOLON);

        const use_decl = try self.allocator.create(AST.UseDecl);
        use_decl.* = .{ .items = try items.toOwnedSlice(), .module = module };

        const node = try self.allocator.create(AST.ASTNode);
        node.* = .{ .use_decl = use_decl };
        return node;
    }

    fn parse_expression(self: *Parser) ParserError!*AST.ASTNode {
        return try self.parse_assignment();
    }

    fn parse_statement(self: *Parser) ParserError!*AST.ASTNode {
        if (try self.match(.IF)) {
            return try self.parse_if_statement();
        } else if (try self.match(.LEFT_BRACE)) {
            return try self.parse_block_statement();
        } else if (try self.match(.FOR)) {
            return try self.parse_for_statement();
        } else if (try self.match(.WHILE)) {
            return try self.parse_while_statement();
        } else if (try self.match(.RETURN)) {
            return try self.parse_return_statement();
        } else if (try self.match(.USE)) {
            return try self.parse_use_statement();
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
        var is_coroutine = false;
        if (try self.match(.PUB)) {
            is_pub = true;
        }
        if (try self.match(.CO)) {
            is_coroutine = true;
        }

        if (try self.match(.VAR)) {
            return try self.parse_var_declaration(is_pub);
        } else if (try self.match(.FN)) {
            return try self.parse_function_declaration(is_pub, is_coroutine);
        } else if (try self.match(.STRUCT)) {
            return try self.parse_struct_declaration(is_pub);
        } else if (try self.match(.TYPE)) {
            return try self.parse_type_declaration(is_pub);
        } else if (try self.match(.IMPL)) {
            return try self.parse_impl_declaration(is_pub);
        } else if (try self.match(.ENUM)) {
            return try self.parse_enum_declaration(is_pub);
        } else if (try self.match(.ERROR)) {
            return try self.parse_error_declaration(is_pub);
        } else {
            if (is_pub) return ParserError.UnexpectedToken;
            return try self.parse_statement();
        }
    }

    fn parse(self: *Parser) ParserError!*AST.ASTNode {
        return try self.parse_declaration();
    }
};
