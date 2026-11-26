// GC stress: closure + coroutine allocation churn.
//
// Each coroutine allocates a full ExecutionState (2048-value stack +
// 128 frames ~= 35KB), so ~150 coroutines ~= 5MB, well past the 1MB
// initial GC threshold. This exercises the recently fixed paths:
// OP_CLOSURE rooting, upvalue capture, and keeping the coroutine
// rooted on the caller stack across OP_RESUME while the GC sweeps
// finished coroutines underneath.

fn make_adder(n: Int) -> fn (Int) -> Int {
	return fn (x: Int) -> Int {
		return x + n;
	};
}

co worker(n: Int) -> (Int, Nil, Int) {
	yield n;
	yield n + 1;
	return n + 2;
}

var i = 0;
while (i < 150000) {
	// Fresh capturing closure every iteration.
	var f = make_adder(i);
	var got = f(i);
	var want = i + i;
	if (got != want) { panic "gc closure"; }

	// Fresh coroutine: drive it through two yields and a return,
	// then drop it so it becomes GC garbage.
	var c = worker(i);
	var a = (resume c).?;
	if (a != i) { panic "gc co yield 1"; }
	var b = (resume c).?;
	var want_b = i + 1;
	if (b != want_b) { panic "gc co yield 2"; }
	var d = resume c;
	var want_d = i + 2;
	if (d != nil or c.returned().? != want_d) { panic "gc co return"; }

	i += 1;
}

"gc closures coroutines done";
