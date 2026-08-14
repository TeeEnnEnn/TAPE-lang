// Empty coroutine: no yields, no return values.
co empty() -> (Nil, Nil) {
}

var empty_co = empty();
resume empty_co;

// Coroutine with an argument, yielding several values before returning nil.
co counter(start: Int) -> (Int, Nil) {
	yield start;
	yield start + 1;
	yield start + 2;
	return nil;
}

var counter_co = counter(10);
var first = resume counter_co;
var second = resume counter_co;
var third = resume counter_co;
var done = resume counter_co;

// Generator: yields inside a loop body.
co gen(limit: Int) -> (Int, Nil) {
	var i = 0;
	while (i < limit) {
		yield i;
		i += 1;
	}
	return nil;
}

var gen_co = gen(3);
resume gen_co;
resume gen_co;
resume gen_co;
resume gen_co;

// Coroutine yielding a value and then returning a real value.
co pipeline() -> (Int, String) {
	yield 1;
	return "finished";
}

var pipe_co = pipeline();
var piped = resume pipe_co;
var final_value = resume pipe_co;

// Nested coroutines: a coroutine creates and resumes another coroutine.
co inner() -> (Int, Nil) {
	yield 7;
	return nil;
}

co outer() -> (Int, Nil) {
	yield 1;
	var c = inner();
	resume c;
	return nil;
}

var outer_co = outer();
resume outer_co;
resume outer_co;


outer_co.finished;
