// `try` unwraps an error union's success value and returns the error early.

error ReadError { NotFound, Denied }

fn read(ok: Bool) -> ReadError!Int {
	if (ok) {
		return 7;
	}
	return ReadError.NotFound;
}

fn read_plus_one(ok: Bool) -> ReadError!Int {
	var value = try read(ok);
	return value + 1;
}

// A successful `try` yields the payload.
var good: Int = read_plus_one(true) catch 0;
if (good != 8) { panic "try should unwrap the success value"; }

// A failed `try` returns from the enclosing function, which the caller can catch.
var missing: Int = read_plus_one(false) catch 99;
if (missing != 99) { panic "try should propagate the error to catch"; }

// Multiple `try` calls compose.
fn read_twice() -> ReadError!Int {
	var a = try read(true);
	var b = try read(true);
	return a + b;
}
var total: Int = read_twice() catch 0;
if (total != 14) { panic "try should compose"; }

// A function returning `!T` accepts any concrete error set.
fn read_any() -> !Int {
	return try read(true);
}
var any_value: Int = read_any() catch 0;
if (any_value != 7) { panic "try should widen a concrete error set"; }
