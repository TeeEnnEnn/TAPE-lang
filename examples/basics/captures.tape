// Captures: `bind (name)` turns a `?T` condition into a non-optional
// binding inside the body. `nil` skips the body (or exits the loop).

// --- if: present / absent / else ---
var maybe: ?Int = 42;
if (maybe) bind (real) {
	if (real != 42) { panic "bind should see 42"; }
} else {
	panic "present optional should take the then branch";
}

maybe = nil;
if (maybe) bind (real) {
	panic "nil should skip the body";
} else {
	// expected
}

// --- else-if chains can capture too ---
var a: ?Int = nil;
var b: ?Int = 7;
if (a) bind (x) {
	panic "a is nil";
} else if (b) bind (y) {
	if (y != 7) { panic "b should bind 7"; }
} else {
	panic "b should be present";
}

// --- the capture is scoped to the body and is immutable ---
var scoped: ?Int = 3;
if (scoped) bind (v) {
	var copy: Int = v;
	if (copy != 3) { panic "capture value"; }
}
// `v` does not exist out here, and `v = 1;` would be a compile error.

// --- aggregates: the binding refers to the real value, so writes stick ---
var arr: ?Array[Int] = nil;
arr = [1, 2, 3];
if (arr) bind (real_arr) {
	real_arr[0] = 9;
}
var check_arr: Array[Int] = arr orelse [0];
if (check_arr[0] != 9) { panic "writes through a captured array should stick"; }

struct Point { pub x: Int, pub y: Int }
var point: ?Point = nil;
point = new Point { x = 1, y = 2 };
if (point) bind (p) {
	p.x = 5;
}
var check_point: Point = point orelse new Point { x = 0, y = 0 };
if (check_point.x != 5) { panic "writes through a captured struct should stick"; }

// --- while: the condition is re-evaluated and rebound each iteration ---
fn at(values: Array[Int], i: Int, n: Int) -> ?Int {
	if (i >= n) { return nil; }
	return values[i];
}
var values = [4, 8, 15];
var total = 0;
var i = 0;
while (at(values, i, 3)) bind (value) {
	total += value;
	i += 1;
}
if (total != 27) { panic "while should sum 4 + 8 + 15"; }
if (i != 3) { panic "while should stop once the optional is nil"; }

// `continue` and `break` still clean up the capture correctly.
var skipped = 0;
var j = 0;
while (at(values, j, 3)) bind (value) {
	j += 1;
	if (value == 8) { continue; }
	skipped += value;
}
if (skipped != 19) { panic "continue should skip 8"; }

var seen = 0;
var k = 0;
while (at(values, k, 3)) bind (value) {
	if (value == 8) { break; }
	seen += 1;
	k += 1;
}
if (seen != 1) { panic "break should stop after 4"; }

// --- present `false` is not nil: only nil skips the body ---
var flag: ?Bool = false;
var ran = 0;
if (flag) bind (f) {
	ran = 1;
	if (f) { panic "a present false must stay false"; }
}
if (ran != 1) { panic "present false should run the body"; }

// --- nested captures and closures ---
var outer: ?Int = 1;
var inner: ?Int = 2;
if (outer) bind (o) {
	if (inner) bind (j) {
		if (o + j != 3) { panic "nested captures"; }
	}
}

fn read_captured(m: ?Int) -> Int {
	var result = 0;
	if (m) bind (v) {
		var get = fn () -> Int { return v; };
		result = get();
	}
	return result;
}
if (read_captured(77) != 77) { panic "closure over a capture"; }
