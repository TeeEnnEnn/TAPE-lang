const std = @import("std");
const Token = @import("../lexer/scanner").Token;

pub const TypeId = u32;

pub const ASTNode = union(enum) {
    // Declarations
    var_decl: *VarDecl,
    fn_decl: *FnDecl,
    type_decl: *TypeDecl,
    struct_decl: *StructDecl,
    enum_decl: *EnumDecl,
    impl_decl: *ImplDecl,
    use_decl: *UseDecl,
    // Statements
    block_stmt: *BlockStmt,
    return_stmt: *ReturnStmt,
    yield_stmt: *YieldStmt,
    give_stmt: *GiveStmt,
    break_stmt: *BreakStmt,
    continue_stmt: *ContinueStmt,
    while_stmt: *WhileStmt,
    for_stmt: *ForStmt,
    if_stmt: *IfStmt,
    expr_stmt: *ExprStmt,

    // Expressions
    assign_expr: *AssignExpr, // =, +=, -=, *=, /=, %=, <<=, >>=, &=, |=, ^=
    identifier_expr: *IdentifierExpr,

    cast_expr: *CastExpr, // as

    // prefix
    unary_expr: *UnaryExpr, // !, ~, -

    // infix
    binary_expr: *BinaryExpr, // +, -, *, /, %, <<, >>, &, |, ^

    // postfix
    call_expr: *CallExpr, // ()
    index_expr: *IndexExpr, // []
    instance_member_expr: *InstanceMemberExpr, // .
    static_member_expr: *StaticMemberExpr, // ::
    error_unwrap_expr: *ErrorUnwrapExpr, // ?

    // primary
    group_expr: *GroupExpr, // ( )
    tuple_expr: *TupleExpr, // ( )
    table_expr: *TableExpr, // { }
    new_expr: *NewExpr, // new
    match_expr: *MatchExpr, // match
    // Literals
    int_lit: *IntLit,
    float_lit: *FloatLit,
    str_lit: *StrLit,
    bool_lit: *BoolLit,
    nil_lit: *NilLit,

    // TypeNodes
    nil_type: *NilType,
    int_type: *IntType,
    float_type: *FloatType,
    str_type: *StrType,
    bool_type: *BoolType,
    array_type: *ArrayType,
    table_type: *TableType,
    vector_type: *VectorType,
    matrix_type: *MatrixType,
    identifier_type: *IdentifierType,
};

// Node Types

/// Variable declaration node.
///
/// ```
/// let 'name': 'type_annotation' = 'initializer';
/// ```
pub const VarDecl = struct {
    modifier_pub: bool,
    name: Token,
    type_annotation: ?*ASTNode,
    initializer: *ASTNode,
};

/// Function declaration node.
///
/// ```
/// fn 'name'('params') -> 'return_type' {
///     'body'
/// }
/// ```
pub const FnDecl = struct {
    modifier_pub: bool,
    modifier_static: bool,
    modifier_co: bool,
    name: Token,
    params: []*TypedNamedField,
    return_type_annotation: ?*ASTNode,
    body: *ASTNode,
};

/// Type declaration node.
///
/// ```
/// type 'name' = 'type_annotation'
/// ```
pub const TypeDecl = struct {
    name: Token,
    type_annotation: ?*ASTNode,
};

/// Struct declaration node.
///
/// ```
/// struct 'name' {
///     'fields'
/// }
/// ```
pub const StructDecl = struct {
    name: Token,
    fields: []*TypedNamedField,
};

/// Enum declaration node.
///
/// ```
/// enum 'name' {
///     'variants'
/// }
/// ```
pub const EnumDecl = struct {
    name: Token,
    variants: []Token,
};

/// Impl declaration node.
///
/// ```
/// impl 'name' {
///     'methods'
/// }
/// ```
pub const ImplDecl = struct {
    name: Token,
    methods: []*ASTNode,
};

/// Use declaration node.
///
/// ```
/// use 'name' as 'alias' from 'module'
/// ```
pub const UseDecl = struct {
    names: []Token,
    aliases: []Token,
    module: Token,
};

/// Block statement node.
///
/// ```
/// { 'stmts' }
/// ```
pub const BlockStmt = struct {
    stmts: []*ASTNode,
};

/// Return statement node.
///
/// ```
/// return ?'expr'
/// ```
pub const ReturnStmt = struct {
    expr: ?*ASTNode,
};

/// Yield statement node.
///
/// ```
/// yield ?'expr'
/// ```
pub const YieldStmt = struct {
    expr: ?*ASTNode,
};

/// Give statement node.
///
/// ```
/// give 'expr'
/// ```
pub const GiveStmt = struct {
    expr: *ASTNode,
};

/// Break statement node.
///
/// ```
/// break
/// ```
pub const BreakStmt = struct {};

/// Continue statement node.
///
/// ```
/// continue
/// ```
pub const ContinueStmt = struct {};

/// While statement node.
///
/// ```
/// while ('expr') 'stmts'
/// ```
pub const WhileStmt = struct {
    expr: *ASTNode,
    stmts: []*ASTNode,
};

/// For statement node.
///
/// ```
/// for 'iterator_name' ('iterator_expr') 'body'
/// ```
pub const ForStmt = struct {
    iterator_name: Token,
    iterator_expr: *ASTNode,
    body: *ASTNode,
};

/// If statement node.
///
/// ```
/// if ('expr') 'then_branch' ('else_branch')
/// ```
pub const IfStmt = struct {
    expr: *ASTNode,
    then_branch: *ASTNode,
    else_branch: ?*ASTNode,
};

/// Expression statement node.
///
/// ```
/// 'expr'
/// ```
pub const ExprStmt = struct {
    expr: *ASTNode,
};

/// Assign expression node.
///
/// ```
/// 'left' 'operator' 'right'
/// ```
pub const AssignExpr = struct {
    left: *ASTNode,
    operator: Token,
    right: *ASTNode,
    resolved_type: TypeId = 0,
};

/// Identifier expression node.
///
/// ```
/// 'name'
/// ```
pub const IdentifierExpr = struct {
    name: Token,
    resolved_type: TypeId = 0,
};

/// Cast expression node.
///
/// ```
/// value 'as' type
/// ```
pub const CastExpr = struct {
    expr: *ASTNode,
    type: *ASTNode,
    resolved_type: TypeId = 0,
};

/// Unary expression node.
///
/// ```
/// operator expr
/// ```
pub const UnaryExpr = struct {
    operator: Token,
    expr: *ASTNode,
    resolved_type: TypeId = 0,
};

/// Binary expression node.
///
/// ```
/// left operator right
/// ```
pub const BinaryExpr = struct {
    operator: Token,
    left: *ASTNode,
    right: *ASTNode,
    resolved_type: TypeId = 0,
};

/// Shape expression node.
///
/// ```
/// shape { field: type, ... }
/// ```
pub const ShapeExpr = struct {
    fields: []*TypedNamedField,
    resolved_type: TypeId = 0,
};

/// Call expression node.
///
/// ```
/// expr(args)
/// ```
pub const CallExpr = struct {
    expr: *ASTNode,
    args: []*ASTNode,
    resolved_type: TypeId = 0,
};

/// Index expression node.
///
/// ```
/// expr[index]
/// ```
pub const IndexExpr = struct {
    expr: *ASTNode,
    index: *ASTNode,
    resolved_type: TypeId = 0,
};

/// Instance member expression node.
///
/// ```
/// expr.member
/// ```
pub const InstanceMemberExpr = struct {
    expr: *ASTNode,
    member: Token,
    resolved_type: TypeId = 0,
};

/// Static member expression node.
///
/// ```
/// expr::member
/// ```
pub const StaticMemberExpr = struct {
    expr: *ASTNode,
    member: Token,
    resolved_type: TypeId = 0,
};

/// Error unwrap expression node.
///
/// ```
/// expr?
/// ```
pub const ErrorUnwrapExpr = struct {
    expr: *ASTNode,
    resolved_type: TypeId = 0,
};

/// Group expression node.
///
/// ```
/// ( expr )
/// ```
pub const GroupExpr = struct {
    expr: *ASTNode,
    resolved_type: TypeId = 0,
};

/// Tuple expression node.
///
/// ```
/// for single item: ( expr,)
/// for multiple items: ( expr, expr, ... )
/// ```
pub const TupleExpr = struct {
    exprs: []*ASTNode,
    resolved_type: TypeId = 0,
};

/// Table expression node.
///
/// ```
/// { key: value, ... }
/// ```
pub const TableExpr = struct {
    keys: []*ASTNode,
    values: []*ASTNode,
    resolved_type: TypeId = 0,
};

pub const StructInitField = struct {
    name: Token,
    value: *ASTNode,
};

/// New expression node.
///
/// ```
/// new struct_name { field: value, ... }
/// ```
pub const NewExpr = struct {
    struct_name: Token,
    fields: []StructInitField,
    resolved_type: TypeId = 0,
};

/// Match expression node.
///
/// ```
/// match expr {
///     pattern => stmt,
///     ...
/// }
/// ```
pub const MatchExpr = struct {
    expr: *ASTNode,
    cases: []*MatchCase,
    resolved_type: TypeId = 0,
};

/// Match case node.
///
/// ```
/// pattern => stmt,
/// ```
pub const MatchCase = struct {
    pattern: *ASTNode,
    stmts: []*ASTNode,
    resolved_type: TypeId = 0,
};

pub const TypedNamedField = struct {
    name: Token,
    type_annotation: *ASTNode,
};

pub const IntLit = struct {
    value: i64,
    resolved_type: TypeId = 0,
};

pub const FloatLit = struct {
    value: f64,
    resolved_type: TypeId = 0,
};

pub const StrLit = struct {
    value: []const u8,
    resolved_type: TypeId = 0,
};

pub const BoolLit = struct {
    value: bool,
    resolved_type: TypeId = 0,
};

pub const NilLit = struct {
    resolved_type: TypeId = 0,
};

pub const NilType = struct {};

pub const IntType = struct {};

pub const FloatType = struct {};

pub const StrType = struct {};

pub const BoolType = struct {};

pub const FileType = struct {};

pub const ArrayType = struct {
    element_type: *ASTNode,
};

pub const TableType = struct {
    key_type: *ASTNode,
    element_type: *ASTNode,
};

pub const VectorType = struct {
    dimension: u32,
};

pub const MatrixType = struct {
    row_dim: u32,
    col_dim: u32,
};

pub const BufferType = struct {};

pub const RangeType = struct {
    start: *ASTNode,
    end: *ASTNode,
    step: u32 = 1,
};

pub const IteratorType = struct {
    element_type: *ASTNode,
};

pub const OptionType = struct {
    element_type: *ASTNode,
};

pub const NeverType = struct {};

pub const TupleType = struct {
    element_types: []*ASTNode,
};

pub const ComplexType = struct {};

pub const IdentifierType = struct {
    name: Token,
};
