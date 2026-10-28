error MyErr {
	Oops,
	BadInput,
	NotFound
}

// A function that returns a union with error: success path
fn may_fail(x: Int) -> Int | MyErr {
	if (x < 0) {
		return MyErr.Oops;
	}
	return x * 2;
}

// Basic try: success unwraps and continues
fn caller_ok(x: Int) -> Int | MyErr {
	var v = try may_fail(x);
	return v + 1;
}
var exp_ok1: Int | MyErr = 11;
if (caller_ok(5) != exp_ok1) { panic "caller_ok 5"; }
var exp_ok2: Int | MyErr = 1;
if (caller_ok(0) != exp_ok2) { panic "caller_ok 0"; }

// Basic try: error causes early return
var exp_err1: Int | MyErr = MyErr.Oops;
if (caller_ok(-1) != exp_err1) { panic "caller_ok err Oops"; }

// Verify early return skips subsequent code
fn early_return_check(x: Int) -> Int | MyErr {
	var a = try may_fail(x);
	// this line should not execute if may_fail returned error
	return a + 100;
}
var exp_early1: Int | MyErr = 106;
if (early_return_check(3) != exp_early1) { panic "early_return success 106"; }
var exp_early2: Int | MyErr = MyErr.Oops;
if (early_return_check(-5) != exp_early2) { panic "early_return error"; }

// Chaining multiple try calls
fn double_try(x: Int) -> Int | MyErr {
	var a = try may_fail(x);
	var b = try may_fail(a);
	return b;
}
var exp_dt1: Int | MyErr = 12;
if (double_try(3) != exp_dt1) { panic "double_try 3 -> 6 -> 12"; }
var exp_dt2: Int | MyErr = 0;
if (double_try(0) != exp_dt2) { panic "double_try 0"; }
var exp_dt3: Int | MyErr = MyErr.Oops;
if (double_try(-1) != exp_dt3) { panic "double_try -1 err"; }

// Propagation through multiple layers
fn inner(x: Int) -> Int | MyErr {
	if (x == 0) {
		return MyErr.BadInput;
	}
	return x;
}
fn middle(x: Int) -> Int | MyErr {
	var v = try inner(x);
	return v + 10;
}
fn outer(x: Int) -> Int | MyErr {
	var v = try middle(x);
	return v + 10;
}
var exp_out1: Int | MyErr = 25;
if (outer(5) != exp_out1) { panic "outer 5"; }
var exp_out2: Int | MyErr = MyErr.BadInput;
if (outer(0) != exp_out2) { panic "outer 0 BadInput"; }

// Try with error on the other side of union (Int is right side vs left side don't matter)
fn may_fail_notfound(id: Int) -> String | MyErr {
	if (id == 0) {
		return MyErr.NotFound;
	}
	return "found";
}
fn caller_str(id: Int) -> String | MyErr {
	var s = try may_fail_notfound(id);
	return s ++ "!";
}
var exp_str1: String | MyErr = "found!";
if (caller_str(1) != exp_str1) { panic "caller_str found"; }
var exp_str2: String | MyErr = MyErr.NotFound;
if (caller_str(0) != exp_str2) { panic "caller_str NotFound"; }

// Try used directly in return expression
fn direct_return(x: Int) -> Int | MyErr {
	return try may_fail(x);
}
var exp_dr1: Int | MyErr = 14;
if (direct_return(7) != exp_dr1) { panic "direct_return 7"; }
var exp_dr2: Int | MyErr = MyErr.Oops;
if (direct_return(-2) != exp_dr2) { panic "direct_return -2"; }

// Try with intermediate variable holding union value
fn with_intermediate(flag: Bool) -> Int | MyErr {
	var tmp: Int | MyErr = MyErr.Oops;
	if (flag) {
		tmp = 10;
	}
	var v = try tmp;
	return v;
}
var exp_wi1: Int | MyErr = 10;
if (with_intermediate(true) != exp_wi1) { panic "with_intermediate true"; }
var exp_wi2: Int | MyErr = MyErr.Oops;
if (with_intermediate(false) != exp_wi2) { panic "with_intermediate false"; }

// Try inside conditional: only executed on one branch
fn branch_try(x: Int, use_try: Bool) -> Int | MyErr {
	if (use_try) {
		var v = try may_fail(x);
		return v;
	} else {
		return 99;
	}
}
var exp_br1: Int | MyErr = 10;
if (branch_try(5, true) != exp_br1) { panic "branch_try true 5"; }
var exp_br2: Int | MyErr = MyErr.Oops;
if (branch_try(-1, true) != exp_br2) { panic "branch_try true -1"; }
var exp_br3: Int | MyErr = 99;
if (branch_try(-1, false) != exp_br3) { panic "branch_try false"; }

// Try chaining with arithmetic after each try
fn arithmetic_after_try(x: Int) -> Int | MyErr {
	var a = try may_fail(x);
	a = a * 2;
	var b = try may_fail(a);
	return b + 1;
}
var exp_aat1: Int | MyErr = 17;
if (arithmetic_after_try(2) != exp_aat1) { panic "arithmetic_after_try 2"; }
var exp_aat2: Int | MyErr = MyErr.Oops;
if (arithmetic_after_try(-1) != exp_aat2) { panic "arithmetic_after_try -1"; }

// Try inside a coroutine (coroutine return type must be union containing error)
co try_in_co(x: Int) -> (Int | MyErr, Nil, Int | MyErr) {
	var v = try may_fail(x);
	yield v;
	return v + 1;
}
var tr1 = try_in_co(4);
var yielded = resume tr1;
var exp_yield: Int | MyErr = 8;
if (yielded != exp_yield) { panic "try_in_co yielded 8"; }
var finished = resume tr1;
var exp_try1: Int | MyErr = 9;
if (finished != exp_try1) { panic "try_in_co finished 9"; }

var tr2 = try_in_co(-1);
var should_be_err = resume tr2;
var exp_try2: Int | MyErr = MyErr.Oops;
if (should_be_err != exp_try2) { panic "try_in_co err Oops"; }

// Ensure success value type is preserved through try (Int stays Int)
fn preserves_type(x: Int) -> Int | MyErr {
	var v: Int = try may_fail(x);
	return v;
}
var exp_pt1: Int | MyErr = 10;
if (preserves_type(5) != exp_pt1) { panic "preserves_type 5"; }
var exp_pt2: Int | MyErr = MyErr.Oops;
if (preserves_type(-1) != exp_pt2) { panic "preserves_type -1"; }

// Nested try: try inside helper that itself uses try
fn helper(x: Int) -> Int | MyErr {
	var v = try may_fail(x);
	return v + 1;
}
fn nested(x: Int) -> Int | MyErr {
	var v = try helper(x);
	return v + 1;
}
var exp_n1: Int | MyErr = 12;
if (nested(5) != exp_n1) { panic "nested 5"; }
var exp_n2: Int | MyErr = MyErr.Oops;
if (nested(-1) != exp_n2) { panic "nested -1"; }
