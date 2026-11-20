// Optionals: `?T` holds either a `T` or `nil`.
var maybe: ?Int = nil;
if (maybe != nil) { panic "a fresh optional should be nil"; }

maybe = 5;
if (maybe == nil) { panic "optional should hold 5"; }
if (maybe != 5) { panic "optional should compare equal to its value"; }

// Reassigning back to nil is allowed
maybe = nil;
if (maybe != nil) { panic "optional should be nil again"; }

// `orelse` supplies a fallback only when the optional is nil
var fallback_used: Int = maybe orelse 42;
if (fallback_used != 42) { panic "orelse should use the fallback for nil"; }

maybe = 7;
var kept: Int = maybe orelse 42;
if (kept != 7) { panic "orelse should keep the value when present"; }

// Chaining keeps the optional type
var a: ?Int = nil;
var b: ?Int = 9;
var chained: ?Int = a orelse b;
if (chained == nil) { panic "chained orelse should be non-nil"; }
if (chained != 9) { panic "chained orelse should be 9"; }

// Optional function results widen from plain values
fn find(ok: Bool) -> ?Int {
	if (ok) {
		return 11;
	}
	return nil;
}
var found: Int = find(true) orelse 0;
if (found != 11) { panic "find(true) should be 11"; }
var missing: Int = find(false) orelse 0;
if (missing != 0) { panic "find(false) should fall back to 0"; }

// `orelse` short-circuits: the RHS is not evaluated when the LHS has a value.
co ticks() -> (Int, Nil, Int) {
	yield 1;
	yield 2;
	return 3;
}
var co1 = ticks();
var present: ?Int = 100;
// The coroutine must NOT be resumed here.
var short_circuit: Int = present orelse resume co1;
if (short_circuit != 100) { panic "orelse should keep the present value"; }
var first_tick = resume co1;
if (first_tick != 1) { panic "orelse resumed the coroutine when it should not have"; }

// ...but it IS evaluated when the optional is nil.
var absent: ?Int = nil;
var next_tick: Int = absent orelse resume co1;
if (next_tick != 2) { panic "orelse should have resumed the coroutine"; }

// Optionals of non-primitive types
var name: ?String = nil;
name = "tape";
if (name == nil) { panic "name should be present"; }
if (name != "tape") { panic "name should equal tape"; }
var display: String = name orelse "unknown";
if (display != "tape") { panic "display should be tape"; }
name = nil;
var missing_name: String = name orelse "unknown";
if (missing_name != "unknown") { panic "missing name should be unknown"; }

// `.?` unwraps a present optional into a plain value. Unwrapping nil panics.
var count: ?Int = 41;
var unwrapped: Int = count.?;
if (unwrapped != 41) { panic "count.? should be 41"; }
if (1 + count.? != 42) { panic "count.? should work inside expressions"; }

// Unwrap works on call results too
if (find(true).? != 11) { panic "find(true).? should be 11"; }

// ...and value parts of a non-primitive optional
var numbers: ?Array[Int] = [3, 4, 5];
if (numbers.?[1] != 4) { panic "numbers.?[1] should be 4"; }

struct Box { pub value: Int }
var box: ?Box = new Box { value = 7 };
if (box.?.value != 7) { panic "box.?.value should be 7"; }

