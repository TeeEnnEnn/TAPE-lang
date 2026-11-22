// `catch` supplies a fallback value when an error union holds an error.

error ReadError { NotFound, Denied }

fn read(ok: Bool) -> ReadError!Int {
	if (ok) {
		return 11;
	}
	return ReadError.NotFound;
}

// Success keeps the payload and ignores the fallback.
var good: Int = read(true) catch 0;
if (good != 11) { panic "catch should keep the success value"; }

// Failure uses the fallback.
var bad: Int = read(false) catch 0;
if (bad != 0) { panic "catch should use the fallback"; }

// The fallback can be any expression compatible with the success type.
var computed: Int = read(false) catch 1 + 2;
if (computed != 3) { panic "catch fallback should be an expression"; }

// Optional success types are supported.
fn maybe(ok: Bool) -> ReadError!?Int {
	if (ok) {
		return 5;
	}
	return ReadError.Denied;
}
var maybe_good: ?Int = maybe(true) catch nil;
if (maybe_good == nil) { panic "catch should keep the optional payload"; }
if (maybe_good != 5) { panic "catch should keep the optional value"; }
var maybe_bad: ?Int = maybe(false) catch nil;
if (maybe_bad != nil) { panic "catch should use the nil fallback"; }
