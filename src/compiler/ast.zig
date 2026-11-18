const std = @import("std");
const Token = @import("scanner.zig").Token;

/// A type's unique identifier
pub const TypeId = u32;

/// A reference to a declaration
/// Used to emit context aware bytecode
pub const DeclRef = union(enum) {
    node: *ASTNode,

    // not AST nodes themselves but "sub-elements" of other AST nodes
    param: struct { func: *ASTNode, index: u32 },
    import: struct { use_decl: *ASTNode, index: u32 },
};

/// A Abstract Syntax Tree Node
pub const ASTNode = union(enum) {
    program: *Program,
    /// Variable Declaration
    var_decl: *VarDecl,
    /// Function Declaration
    fn_decl: *FnDecl,
    /// Type declaration
    type_decl: *TypeDecl,
    /// Struct declaration
    struct_decl: *StructDecl,
    /// Enum declaration
    enum_decl: *EnumDecl,
    /// Error declaration
    error_decl: *ErrorDecl,
    /// Coroutine declaration
    co_decl: *CoDecl,
    /// Use declaration
    use_decl: *UseDecl,

    /// Native type declaration
    native_type_decl: *NativeTypeDecl,
    /// Native function declaration
    native_fn_decl: *NativeFnDecl,

    /// Block of code (collection of statements in +1 scope)
    block_stmt: *BlockStmt,
    /// `return value`
    return_stmt: *ReturnStmt,
    /// `yield value`
    yield_expr: *YieldExpr,

    /// `give value`
    give_stmt: *GiveStmt,
    /// `break`
    break_stmt: *BreakStmt,
    /// `continue`
    continue_stmt: *ContinueStmt,
    while_stmt: *WhileStmt,
    for_stmt: *ForStmt,
    if_stmt: *IfStmt,
    expr_stmt: *ExprStmt,
    panic_stmt: *PanicStmt,

    // Expressions
    assign_expr: *AssignExpr, // =, +=, -=, *=, /=, %=, <<=, >>=, &=, |=, ^=
    identifier_expr: *IdentifierExpr,

    // prefix
    unary_expr: *UnaryExpr, // not, ~, -

    // infix
    binary_expr: *BinaryExpr, // +, -, *, /, %, <<, >>, &, |, ^

    // postfix
    call_expr: *CallExpr, // ()
    index_expr: *IndexExpr, // []
    dot_expr: *DotExpr, // .

    // unary
    try_expr: *TryExpr, // try
    /// `resume value`
    resume_expr: *ResumeExpr,

    // primary
    /// Array expression node.
    ///
    /// ```
    /// [ ]
    /// ```
    array_expr: *ArrayExpr,

    group_expr: *GroupExpr, // ( )
    tuple_expr: *TupleExpr, // ( )
    table_expr: *TableExpr, // { }
    new_expr: *NewExpr, // new
    match_expr: *MatchExpr, // match
    anon_fn_expr: *AnonFnExpr, // fn () -> {}
    anon_co_expr: *AnonCoExpr, // co () -> {}
    // Literals
    int_lit: *IntLit,
    float_lit: *FloatLit,
    str_lit: *StrLit,
    bool_lit: *BoolLit,
    nil_lit: *NilLit,

    default_pat: *DefaultPat,

    // TypeNodes
    nil_type: *NilType,
    int_type: *IntType,
    float_type: *FloatType,
    string_type: *StringType,
    bool_type: *BoolType,
    array_type: *ArrayType,
    table_type: *TableType,
    range_type: *RangeType,
    never_type: *NeverType,
    tuple_type: *TupleType,
    identifier_type: *IdentifierType,
    fn_type: *FnType,
    co_type: *CoType,
    optional_type: *OptionalType,
};

// Node Types

/// Program node.
///
/// ```
///
/// ```
pub const Program = struct {
    declarations: []*ASTNode,
};

/// Variable declaration node.
///
/// ```
/// let 'name': 'type_annotation' = 'initializer';
/// ```
pub const VarDecl = struct {
    modifier_pub: bool,
    is_const: bool,
    name: Token,
    type_annotation: ?*ASTNode,
    initializer: *ASTNode,
    line: usize,
    column: usize,
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
    name: Token,
    params: []*TypedNamedField,
    return_type_annotation: *ASTNode,
    body: *ASTNode,
    line: usize,
    column: usize,
};

/// Function declaration node.
///
/// ```
/// co 'name'('params') -> '(yield_type, return_type)' {
///     'body'
/// }
/// ```
pub const CoDecl = struct {
    modifier_pub: bool,
    name: Token,
    params: []*TypedNamedField,
    return_type_annotation: *ASTNode,
    yield_type_annotation: *ASTNode,
    resume_with_type_annotation: *ASTNode,
    body: *ASTNode,
    line: usize,
    column: usize,
};

/// Type declaration node.
///
/// ```
/// type 'name' = 'type_annotation'
/// ```
pub const TypeDecl = struct {
    modifier_pub: bool,
    name: Token,
    type_annotation: *ASTNode,
    line: usize,
    column: usize,
};

/// Struct declaration node.
///
/// ```
/// struct 'name' {
///     'fields'
///     'methods'
/// }
/// ```
pub const StructDecl = struct {
    modifier_pub: bool,
    name: Token,
    fields: []*TypedNamedStructField,
    methods: []*StructMethodField,
    line: usize,
    column: usize,
};

/// Enum declaration node.
///
/// ```
/// enum 'name' {
///     'variants'
/// }
/// ```
pub const EnumDecl = struct {
    modifier_pub: bool,
    name: Token,
    variants: []Token,
    line: usize,
    column: usize,
};

/// Error declaration node.
///
/// ```
/// error 'name' {
///     'variants'
/// }
/// ```
pub const ErrorDecl = struct {
    modifier_pub: bool,
    name: Token,
    variants: []Token,
    line: usize,
    column: usize,
};

/// Block statement node.
///
/// ```
/// { 'stmts' }
/// ```
pub const BlockStmt = struct {
    stmts: []*ASTNode,
    line: usize,
    column: usize,
};

/// Return statement node.
///
/// ```
/// return ?'expr'
/// ```
pub const ReturnStmt = struct {
    expr: ?*ASTNode,
    line: usize,
    column: usize,
};

/// Resume Expression node.
///
/// ```
/// resume 'expr'
/// ```
pub const ResumeExpr = struct {
    expr: *ASTNode,
    arg: ?*ASTNode = null,
    resolved_type: TypeId = 0,
    line: usize,
    column: usize,
};

/// Try expression node.
///
/// ```
/// try 'expr'
/// ```
pub const TryExpr = struct {
    expr: *ASTNode,
    resolved_type: TypeId = 0,
    line: usize,
    column: usize,
};

/// Yield statement node.
///
/// ```
/// yield ?'expr'
/// ```
pub const YieldExpr = struct {
    expr: *ASTNode,
    line: usize,
    column: usize,
    resolved_type: TypeId = 0,
};

/// Give statement node.
///
/// ```
/// give 'expr'
/// ```
pub const GiveStmt = struct {
    expr: *ASTNode,
    line: usize,
    column: usize,
};

/// Break statement node.
///
/// ```
/// break
/// ```
pub const BreakStmt = struct {
    line: usize,
    column: usize,
};

/// Continue statement node.
///
/// ```
/// continue
/// ```
pub const ContinueStmt = struct {
    line: usize,
    column: usize,
};

/// While statement node.
///
/// ```
/// while ('expr') 'body'
/// ```
pub const WhileStmt = struct {
    condition: *ASTNode,
    body: *ASTNode,
    line: usize,
    column: usize,
};

/// For statement node.
///
/// ```
/// for 'iterator_name' 'in' ('iterator_expr') 'body'
/// ```
pub const ForStmt = struct {
    iterator_name: Token,
    iterator_expr: *ASTNode,
    body: *ASTNode,
    line: usize,
    column: usize,
};

/// If statement node.
///
/// ```
/// if ('expr') 'then_branch' ('else_branch')
/// ```
pub const IfStmt = struct {
    condition: *ASTNode,
    then_branch: *ASTNode,
    else_branch: ?*ASTNode,
    line: usize,
    column: usize,
};

/// Panic statement node.
///
/// ```
/// panic 'expr'
/// ```
pub const PanicStmt = struct {
    expr: *ASTNode,
    line: usize,
    column: usize,
};

/// Expression statement node.
///
/// ```
/// 'expr'
/// ```
pub const ExprStmt = struct {
    expr: *ASTNode,
    line: usize,
    column: usize,
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
    line: usize,
    column: usize,
};

/// Identifier expression node.
///
/// ```
/// 'name'
/// ```
pub const IdentifierExpr = struct {
    name: Token,
    resolved_type: TypeId = 0,
    resolved_decl: ?DeclRef = null,
    line: usize,
    column: usize,
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
    line: usize,
    column: usize,
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
    line: usize,
    column: usize,
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
    line: usize,
    column: usize,
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
    line: usize,
    column: usize,
};

/// Array expression node.
///
/// ```
/// [expr, ...]
/// ```
pub const ArrayExpr = struct {
    elements: []*ASTNode,
    resolved_type: TypeId = 0,
    line: usize,
    column: usize,
};

/// dot expression node.
///
/// ```
/// expr.member
/// ```
pub const DotExpr = struct {
    expr: *ASTNode,
    member: Token,
    resolved_type: TypeId = 0,
    line: usize,
    column: usize,
};

/// Group expression node.
///
/// ```
/// ( expr )
/// ```
pub const GroupExpr = struct {
    expr: *ASTNode,
    resolved_type: TypeId = 0,
    line: usize,
    column: usize,
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
    line: usize,
    column: usize,
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
    line: usize,
    column: usize,
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
    line: usize,
    column: usize,
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
    line: usize,
    column: usize,
};

/// Match case node.
///
/// ```
/// pattern => stmt,
/// ```
pub const MatchCase = struct {
    pattern: *ASTNode,
    stmt: *ASTNode,
    resolved_type: TypeId = 0,
    line: usize,
    column: usize,
};

/// Anonymous function node
///
/// ```
/// fn () -> 'type_annotation' 'body'
/// ```
pub const AnonFnExpr = struct {
    params: []*TypedNamedField,
    return_type_annotation: *ASTNode,
    body: *ASTNode,
    resolved_type: TypeId = 0,
    line: usize,
    column: usize,
};

/// Anonymous coroutine node
///
/// ```
/// co () -> 'type_annotation' 'body'
/// ```
pub const AnonCoExpr = struct {
    params: []*TypedNamedField,
    return_type_annotation: *ASTNode,
    yield_type_annotation: *ASTNode,
    resume_with_type_annotation: *ASTNode,
    body: *ASTNode,
    resolved_type: TypeId = 0,
    line: usize,
    column: usize,
};

pub const TypedNamedField = struct {
    name: Token,
    type_annotation: *ASTNode,
};

pub const TypedNamedStructField = struct {
    name: Token,
    type_annotation: *ASTNode,
    is_pub: bool,
    has_default: bool,
    default_value: ?*ASTNode,
};

pub const StructMethodField = struct {
    name: Token,
    method: *ASTNode,
    is_pub: bool, // is accessible from outside the struct
};

pub const ImportItem = struct {
    name: Token,
    alias: ?Token,
};

/// Use declaration node.
///
/// ```
/// use 'name' as 'alias' from 'module'
/// ```
pub const UseDecl = struct {
    modifier_pub: bool,
    items: []ImportItem,
    module: Token,
    /// The resolved path of the module.
    resolved_module_path: []const u8,
    line: usize,
    column: usize,
};

pub const IntLit = struct {
    value: i64,
    resolved_type: TypeId = 0,
    line: usize,
    column: usize,
};

pub const FloatLit = struct {
    value: f64,
    resolved_type: TypeId = 0,
    line: usize,
    column: usize,
};

pub const StrLit = struct {
    value: []const u8,
    resolved_type: TypeId = 0,
    line: usize,
    column: usize,
};

pub const BoolLit = struct {
    value: bool,
    resolved_type: TypeId = 0,
    line: usize,
    column: usize,
};

pub const NilLit = struct {
    resolved_type: TypeId = 0,
    line: usize,
    column: usize,
};

pub const NilType = struct {};

pub const IntType = struct {};

pub const FloatType = struct {};

pub const StringType = struct {};

pub const BoolType = struct {};

pub const ArrayType = struct {
    element_type: *ASTNode,
};

pub const TableType = struct {
    key_type: *ASTNode,
    element_type: *ASTNode,
};

pub const RangeType = struct {
    start: *ASTNode,
    end: *ASTNode,
    step: u32 = 1,
};

pub const NeverType = struct {};

pub const TupleType = struct {
    element_types: []*ASTNode,
};

pub const FnType = struct {
    params: []*ASTNode,
    return_type: *ASTNode,
};

pub const CoType = struct {
    params: []*ASTNode,
    return_type: *ASTNode,
    yield_type: *ASTNode,
    resume_with_type: *ASTNode,
};

pub const IdentifierType = struct {
    name: Token,
    source_file: []const u8,
    generic_args: ?[]*ASTNode,
};

pub const OptionalType = struct {
    inner: *ASTNode,
};

// match patterns

pub const DefaultPat = struct {};

// native types

/// Does not have a body
/// The functionality exists outside of TAPE
/// `native fn open(fname: String) -> File`
pub const NativeFnDecl = struct {
    modifier_pub: bool,
    name: Token,
    params: []*TypedNamedField,
    return_type_annotation: *ASTNode,
    line: usize,
    column: usize,
};

/// Does not have a type annotation
/// The type is opaque
/// `native type FileHandle;`
pub const NativeTypeDecl = struct {
    modifier_pub: bool,
    name: Token,
    line: usize,
    column: usize,
};
