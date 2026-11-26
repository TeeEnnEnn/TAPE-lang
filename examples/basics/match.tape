enum Color {
    Red,
    Green,
    Blue,
}

// 1. Value-producing match on Enums with `give`
var c = Color.Green;
var code = match (c) {
    Color.Red => give 1;,
    Color.Green => give 2;,
    Color.Blue => give 3;,
    default => give 0;
};

if (code != 2) { panic "enum match failed"; }

// 2. Value-producing match with block and give
var desc = match (code) {
    1 => {
        give "one";
    },
    2 => {
        give "two";
    },
    default => {
        give "other";
    },
};

if (desc != "two") { panic "block give match failed"; }

// 3. Statement-only match (no give, just statements)
var counter = 0;
match (code) {
    1 => counter = 10;,
    2 => counter = 20;,
    default => counter = 100;,
};

if (counter != 20) { panic "statement match failed"; }

// 4. Match with return inside arm
fn test_return(x: Int) -> Int {
    match (x) {
        10 => return 100;,
        default => return 0;,
    };
}

if (test_return(10) != 100) { panic "return in match failed"; }
if (test_return(5) != 0) { panic "default return in match failed"; }

// 5. Exhaustive enum without default (should be exhaustive)
var code_exhaustive = match (c) {
    Color.Red => give 10;,
    Color.Green => give 20;,
    Color.Blue => give 30;
};
if (code_exhaustive != 20) { panic "exhaustive enum no default failed"; }

// 6. Exhaustive error without default
error MyErr {
    Oops,
    BadInput,
    NotFound
}
var e = MyErr.Oops;
var err_code = match (e) {
    MyErr.Oops => give 1;,
    MyErr.BadInput => give 2;,
    MyErr.NotFound => give 3;
};
if (err_code != 1) { panic "exhaustive error no default failed"; }

// 7. Error with default
var err_with_default = match (e) {
    MyErr.Oops => give 100;,
    default => give 0;
};
if (err_with_default != 100) { panic "error with default failed"; }

// 8. Primitive patterns require default - Int, String, Bool
var s_val = "hi";
var s_code = match (s_val) {
    "hi" => give 1;,
    "bye" => give 2;,
    default => give 0;
};
if (s_code != 1) { panic "string match failed"; }

var b_val = true;
var b_code = match (b_val) {
    true => give 10;,
    false => give 20;
};
if (b_code != 10) { panic "bool exhaustive failed"; }

var int_with_default = match (42) {
    1 => give 1;,
    2 => give 2;,
    default => give 99;
};
if (int_with_default != 99) { panic "int default failed"; }

// 9. Default can be anywhere (first, middle, last) - order matters
var def_first = match (code) {
    default => give 999;,
    1 => give 1;,
    2 => give 2;
};
if (def_first != 999) { panic "default first failed"; }

var def_middle = match (code) {
    1 => give 1;,
    default => give 888;,
    2 => give 2;
};
// code is 2, but default is before 2, so default matches (first catch-all wins)
if (def_middle != 888) { panic "default middle failed"; }

// 10. Deep give detection (give inside if/block)
var deep_give = match (code) {
    1 => {
        if (true) {
            give 100;
        }
    },
    2 => {
        if (true) {
            give 200;
        } else {
            give 300;
        }
    },
    default => give 0;
};
if (deep_give != 200) { panic "deep give failed"; }

// 11. Nested match with give isolation (inner String, outer Int) - tests OP_GIVE_POP
var nested = match (c) {
    Color.Red => give 1;,
    default => {
        var inner_e = MyErr.BadInput;
        var inner = match (inner_e) {
            MyErr.Oops => give "oops";,
            MyErr.BadInput => give "bad";,
            MyErr.NotFound => give "notfound";
        };
        if (inner != "bad") { panic "nested inner failed"; }
        give 42;
    }
};
if (nested != 42) { panic "nested give isolation failed"; }

// 12. Match as expression (in call, binary, return)
fn id_fn(x: Int) -> Int {
    return match (x) {
        1 => give 10;,
        default => give 20;
    };
}
if (id_fn(1) != 10) { panic "match as return failed"; }
var y = match (code) {
    1 => give 1;,
    2 => give 2;,
    default => give 0;
} + 5;
if (y != 7) { panic "match as binary failed"; }

fn takes_int(x: Int) -> Int {
    return x * 2;
}
var call_arg = takes_int(match (code) {
    1 => give 3;,
    default => give 4;
});
if (call_arg != 8) { panic "match as arg failed"; }

// 13. Primitive match requires default, fallback via default
var nil_fallback = match (99) {
    1 => give 1;,
    default => give 99;
};
if (nil_fallback != 99) { panic "fallback failed"; }

// 13b. Statement-only match with no give returns Nil (still needs default for primitive)
var stmt_nil = 0;
match (99) {
    1 => stmt_nil = 1;,
    default => stmt_nil = 2;
};
if (stmt_nil != 2) { panic "stmt fallback failed"; }

// 14. Empty match on Never is exhaustive
fn never_match(x: Never) -> Int {
    match (x) {};
    return 42;
}
var empty_enum_check = match (c) {
    Color.Red => give 1;,
    Color.Green => give 2;,
    Color.Blue => give 3;
};
if (empty_enum_check != 2) { panic "empty check failed"; }

// 15. Match with panic arms satisfies completeness
fn with_panic(c: Color) -> Int {
    match (c) {
        Color.Red => panic "red panic";,
        Color.Green => return 2;,
        Color.Blue => return 3;,
        default => return 0;
    };
}
if (with_panic(Color.Green) != 2) { panic "panic arm failed"; }

// 16. Match inside coroutine with yield
co match_in_co(x: Int) -> (Int, Nil, Int) {
    var v = match (x) {
        1 => give 10;,
        default => give 20;
    };
    yield v;
    return v + 1;
}
var co_h = match_in_co(1);
if ((resume co_h).? != 10) { panic "match in co yield failed"; }
if (resume co_h != nil or co_h.returned().? != 11) { panic "match in co return failed"; }
