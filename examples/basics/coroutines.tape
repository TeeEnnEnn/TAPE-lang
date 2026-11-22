// Empty coroutine: no yields, no return values.
co empty() -> (Nil, Nil, Nil) {
}

var empty_co = empty();
var empty_res = resume empty_co;
if (empty_res != nil or not empty_co.is_finished()) { panic "empty coroutine completion"; }

// Coroutine with an argument, yielding several values before returning.
co counter(start: Int) -> (Int, Nil, Int) {
	yield start;
	yield start + 1;
	yield start + 2;
	return 0;
}

var counter_co = counter(10);
var first = (resume counter_co).?;
if (first != 10) { panic "first 10"; }
var second = (resume counter_co).?;
if (second != 11) { panic "second 11"; }
var third = (resume counter_co).?;
if (third != 12) { panic "third 12"; }
var done = resume counter_co;
if (done != nil or counter_co.returned().? != 0) { panic "done 0"; }

// Generator: yields inside a loop body.
co gen(limit: Int) -> (Int, Nil, Int) {
	var i = 0;
	while (i < limit) {
		yield i;
		i += 1;
	}
	return limit;
}

var gen_co = gen(3);
var g0 = (resume gen_co).?;
if (g0 != 0) { panic "g0 0"; }
var g1 = (resume gen_co).?;
if (g1 != 1) { panic "g1 1"; }
var g2 = (resume gen_co).?;
if (g2 != 2) { panic "g2 2"; }
var g3 = resume gen_co;
if (g3 != nil or gen_co.returned().? != 3) { panic "gen completion"; }

// Coroutine yielding a value and then returning a value.
co pipeline() -> (Int, Nil, Int) {
	yield 1;
	return 2;
}

var pipe_co = pipeline();
var piped = (resume pipe_co).?;
if (piped != 1) { panic "piped 1"; }
var final_value = resume pipe_co;
if (final_value != nil or pipe_co.returned().? != 2) { panic "final 2"; }

// Nested coroutines: a coroutine creates and resumes another coroutine.
co inner() -> (Int, Nil, Int) {
	yield 7;
	return -1;
}

co outer() -> (Int, Nil, Int) {
	yield 1;
	var c = inner();
	var iv = (resume c).?;
	if (iv != 7) { panic "inner yield 7"; }
	return -1;
}

var outer_co = outer();
var o1 = (resume outer_co).?;
if (o1 != 1) { panic "outer o1 1"; }
var o2 = resume outer_co;
if (o2 != nil or outer_co.returned().? != -1) { panic "outer completion"; }

// Bidirectional: a coroutine yields a value, the resumer passes a value back
co echo(initial: Int) -> (Int, Int, Int) {
	var received = yield initial;
	return received;
}

var echo_co = echo(5);
var yielded = (resume echo_co with 100).?;
if (yielded != 5) { panic "yielded 5"; }
var finished = resume echo_co with 200;
if (finished != nil or echo_co.returned().? != 200) { panic "finished 200"; }

var echo2 = echo(10);
var y1 = (resume echo2 with 999).?;
if (y1 != 10) { panic "echo2 y1 10"; }
var f2 = resume echo2 with 888;
if (f2 != nil or echo2.returned().? != 888) { panic "echo2 returned 888"; }
