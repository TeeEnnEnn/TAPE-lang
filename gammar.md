program         ::= declaration* EOF

/* --- Declarations --- */
declaration     ::= modifier* ( var_decl | fn_decl | type_decl | struct_decl | enum_decl | impl_decl )
                  | use_decl
                  | statement

modifier        ::= 'pub' | 'co' | 'static'

use_decl        ::= 'use' import_item (',' import_item)* 'from' STRING ';'


var_decl        ::= 'var' IDENTIFIER (':' type_expr)? '=' expression ';'

fn_decl         ::= 'fn' IDENTIFIER '(' parameters? ')' ('->' type_expr)? block

type_decl       ::= 'type' IDENTIFIER '=' type_expr ';'

struct_decl     ::= 'struct' IDENTIFIER '{' struct_fields? '}'

enum_decl       ::= 'enum' IDENTIFIER '{' enum_variants? '}'

impl_decl       ::= 'impl' IDENTIFIER '{' (modifier* fn_decl)* '}'

/* --- Types --- */
type_expr       ::= IDENTIFIER ('[' type_expr (',' type_expr)* ']')?  /* Generics e.g. Array[Int] */
                  | type_expr '|' type_expr                           /* Unions e.g. Float | Nil */
                  | 'shape' '{' struct_fields? '}'
                  | '(' type_expr_list? ')'                           /* Tuple Type */
                  | 'fn' '(' type_expr_list? ')' ('->' type_expr)?    /* Function Type */

type_expr_list  ::= type_expr (',' type_expr)* ','?

parameters      ::= param (',' param)* ','?
param           ::= IDENTIFIER ':' type_expr

struct_fields   ::= field (',' field)* ','?
field           ::= IDENTIFIER ':' type_expr

enum_variants   ::= IDENTIFIER (',' IDENTIFIER)* ','?

/* --- Statements --- */
statement       ::= expression ';'
                  | block
                  | 'return' expression? ';'
                  | 'yield' expression? ';'
                  | 'give' expression ';'
                  | 'break' ';'
                  | 'continue' ';'
                  | 'while' '(' expression ')' block
                  | 'for' '(' 'var' IDENTIFIER 'in' expression ')' block
                  | 'if' expression block ('else' (block | 'if' expression block))*

block           ::= '{' declaration* '}'

/* --- Expressions --- */
expression      ::= assignment

assignment      ::= range (assign_op assignment)?
assign_op       ::= '=' | '+=' | '-=' | '*=' | '/=' | '++'

range           ::= logic_or ('..' logic_or)?

logic_or        ::= logic_and ('or' logic_and | 'orelse' logic_and)*
logic_and       ::= bit_or ('and' bit_or)*
bit_or          ::= bit_xor ('|' bit_xor)*
bit_xor         ::= bit_and ('^' bit_and)*
bit_and         ::= equality ('&' equality)*
equality        ::= comparison (('==' | '!=') comparison)*
comparison      ::= bit_shift (('<' | '<=' | '>' | '>=') bit_shift)*
bit_shift       ::= term (('<<' | '>>') term)*
term            ::= factor (('-' | '+') factor)*
factor          ::= unary (('/' | '*' | '%' | '**') unary)*

unary           ::= ('not' | '-' | '~' | 'resume') unary
                  | cast

cast            ::= postfix ('as' type_expr)*

postfix         ::= primary (
                      '(' arguments? ')'            /* Call */
                    | '[' expression ']'            /* Index */
                    | '.' IDENTIFIER                /* Instance member access */
                    | '::' IDENTIFIER               /* Static member access */
                    | '?'                           /* Error unwrap operator */
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
expression_or_type ::= expression | type_expr

import_item     ::= IDENTIFIER ('as' IDENTIFIER)?

/* --- Lexical / Tokens --- */
IDENTIFIER      ::= [a-zA-Z_] [a-zA-Z0-9_]*
NUMBER          ::= [0-9]+ ('.' [0-9]+)? ([eE] [-+]? [0-9]+)?
STRING          ::= '"' [^"]* '"' | "'" [^']* "'"
COMMENT         ::= '//' [^\n]*
