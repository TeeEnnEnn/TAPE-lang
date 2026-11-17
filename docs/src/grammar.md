program         ::= declaration* EOF

/* --- Declarations --- */
declaration     ::= modifier* ( var_decl | fn_decl | type_decl | struct_decl | enum_decl | co_decl | error_decl  | use_decl)
                  | statement

modifier        ::= 'pub' 

use_decl        ::= modifier* 'use' import_item (',' import_item)* 'from' STRING ';'

var_decl        ::= ('var' | 'const') IDENTIFIER (':' type_expr)? '=' expression ';'

fn_decl         ::= 'fn' IDENTIFIER '(' parameters? ')' ('->' type_expr) statement

co_decl         ::= 'co' IDENTIFIER '(' parameters? ')' ('->' '(' type_expr ',' type_expr ',' type_expr ')' statement)

type_decl       ::= 'type' IDENTIFIER '=' type_expr ';'

struct_decl     ::= 'struct' IDENTIFIER '{' struct_members? '}'
struct_members  ::= struct_member (',' struct_member)* ','?
struct_member   ::= modifier* struct_field
                  | modifier* method_fn_decl
                  | modifier* method_co_decl

struct_field    ::= IDENTIFIER ':' type_expr ('=' expression)?
method_fn_decl  ::= 'fn' IDENTIFIER '(' method_parameters? ')' ('->' type_expr) statement
method_co_decl  ::= 'co' IDENTIFIER '(' method_parameters? ')' ('->' '(' type_expr ',' type_expr ',' type_expr ')' statement)
method_parameters ::= 'self' (',' parameters)? | parameters

enum_decl       ::= 'enum' IDENTIFIER '{' enum_variants? '}'

error_decl      ::= 'error' IDENTIFIER '{' enum_variants? '}'

/* --- Types --- */
type_expr       ::= IDENTIFIER ('[' type_expr (',' type_expr)* ']')?  /* Generics e.g. Array[Int] */
                  | 'Nil' | 'Bool' | 'Int' | 'Float' | 'String'
                  | 'Never'
                  | 'Array' '[' type_expr ']'
                  | 'Table' '[' type_expr ',' type_expr ']'
                  | 'Range' '[' type_expr ',' type_expr (',' INT)? ']'
                  | 'shape' '{' struct_fields? '}'
                  | '(' type_expr_list? ')'                           /* Tuple Type */
                  | 'fn' '(' type_expr_list? ')' ('->' type_expr)?    /* Function Type */
                  | 'co' '(' type_expr_list? ')' '->' 'co' '[' type_expr ',' type_expr ']' /* Coroutine Type */

type_expr_list  ::= type_expr (',' type_expr)* ','?

parameters      ::= param (',' param)* ','?
param           ::= IDENTIFIER ':' type_expr
/* In a struct method, an untyped `self` may appear only as the first parameter. */

struct_fields   ::= field (',' field)* ','?
field           ::= IDENTIFIER ':' type_expr

enum_variants   ::= IDENTIFIER (',' IDENTIFIER)* ','?

/* --- Statements --- */
statement       ::= expression ';'
                  | block
                  | 'return' expression? ';'
                  | 'give' expression ';'
                  | 'panic' expression ';'
                  | 'break' ';'
                  | 'continue' ';'
                  | 'while' '(' expression ')' block
                  | 'for' '(' 'var' IDENTIFIER 'in' expression ')' block
                  | 'if' expression block ('else' (block | 'if' expression block))*

block           ::= '{' declaration* '}'

/* --- Expressions --- */
expression      ::= assignment

assignment      ::= range (assign_op assignment)?
assign_op       ::= '=' | '+=' | '-=' | '*=' | '/=' | '%=' | '**=' | '++='

range           ::= logic_or ('..' logic_or)?

logic_or        ::= logic_and ('or' logic_and)*
logic_and       ::= bit_or ('and' bit_or)*
bit_or          ::= bit_xor ('|' bit_xor)*
bit_xor         ::= bit_and ('^' bit_and)*
bit_and         ::= equality ('&' equality)*
equality        ::= comparison (('==' | '!=') comparison)*
comparison      ::= bit_shift (('<' | '<=' | '>' | '>=') bit_shift)*
bit_shift       ::= term (('<<' | '>>') term)*
term            ::= factor (('-' | '+' | '++') factor)*
factor          ::= unary (('/' | '*' | '%' | '**') unary)*

unary           ::= ('not' | '-' | '~' | 'resume' | 'try' | 'yield') unary
                  | cast

postfix         ::= primary (
                      '(' arguments? ')'            /* Call */
                    | '[' expression ']'            /* Index */
                    | '.' IDENTIFIER                /* Field, instance method, or type-associated function */
                  )*

primary         ::= IDENTIFIER
                  | NUMBER
                  | STRING
                  | 'true' | 'false' | 'nil'
                  | '(' ')'                                      /* Empty tuple */
                  | '(' expression ')'                           /* Grouping */
                  | '(' expression ',' arguments? ')'            /* Tuple (1 or more elements) */
                  | '[' arguments? ']'              /* Array literal */
                  | '{' table_entries? '}'          /* Table literal */
                  | 'new' IDENTIFIER '{' struct_inits? '}'
                  | 'match' '(' expression ')' '{' match_arms? '}'
                  | 'fn' '(' parameters? ')' ('->' type_expr)? statement

/* --- Helpers --- */
arguments       ::= expression (',' expression)* ','?

table_entries   ::= table_entry (',' table_entry)* ','?
table_entry     ::= STRING ':' expression

struct_inits    ::= struct_init (',' struct_init)* ','?
struct_init     ::= IDENTIFIER '=' expression

match_arms      ::= match_arm*
match_arm       ::= expression_or_type '=>' statement
                  | 'default' '=>' statement
expression_or_type ::= expression | type_expr

import_item     ::= IDENTIFIER ('as' IDENTIFIER)?

/* --- Lexical / Tokens --- */
IDENTIFIER      ::= [a-zA-Z_] [a-zA-Z0-9_]*
NUMBER          ::= [0-9]+ ('.' [0-9]+)? ([eE] [-+]? [0-9]+)?
STRING          ::= '"' [^"]* '"' | "'" [^']* "'"
COMMENT         ::= '//' [^\n]*
