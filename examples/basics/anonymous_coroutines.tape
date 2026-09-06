// Empty anonymous coroutine (no yields, returns nil)
var empty_anon = co () -> (Nil, Nil, Nil) {
	return nil;
};
var empty_co = empty_anon();
var empty_res = resume empty_co;
if (empty_res != nil) { panic "empty anon nil"; }

// Anonymous coroutine yielding several values
var counter_anon = co (start: Int) -> (Int, Nil, Int) {
	yield start;
	yield start + 1;
	yield start + 2;
	return 0;
};
var c1 = counter_anon(10);
if (resume c1 != 10) { panic "anon counter 10"; }
if (resume c1 != 11) { panic "anon counter 11"; }
if (resume c1 != 12) { panic "anon counter 12"; }
if (resume c1 != 0) { panic "anon counter done"; }

// Generator pattern via anonymous coroutine
var gen_anon = co (limit: Int) -> (Int, Nil, Int) {
	var i = 0;
	while (i < limit) {
		yield i;
		i += 1;
	}
	return -1;
};
var g = gen_anon(3);
if (resume g != 0) { panic "gen anon 0"; }
if (resume g != 1) { panic "gen anon 1"; }
if (resume g != 2) { panic "gen anon 2"; }
if (resume g != -1) { panic "gen anon -1"; }

// Typed variable holding anonymous coroutine
var typed_co: co (Int) -> co [Int, Nil, Int] = co (n: Int) -> (Int, Nil, Int) {
	yield n;
	return n * 2;
};
var tc = typed_co(5);
if (resume tc != 5) { panic "typed_co yield"; }
if (resume tc != 10) { panic "typed_co return"; }

// Bidirectional anonymous coroutine (resume with value) via closure capture
fn make_echo(initial: Int) -> co () -> co [Int, Int, Int] {
	return co () -> (Int, Int, Int) {
		var received = yield initial;
		return received;
	};
}
var e1 = make_echo(5)();
var e1_y = resume e1 with 100;
if (e1_y != 5) { panic "echo anon yielded 5"; }
var e1_f = resume e1 with 200;
if (e1_f != 200) { panic "echo anon returned 200"; }

var e2 = make_echo(10)();
var e2_y = resume e2 with 999;
if (e2_y != 10) { panic "echo2 anon 10"; }
var e2_f = resume e2 with 888;
if (e2_f != 888) { panic "echo2 anon 888"; }

// Anonymous coroutine capturing outer local (closure)
fn make_yielder(base: Int) -> co () -> co [Int, Nil, Int] {
	return co () -> (Int, Nil, Int) {
		yield base;
		yield base + 1;
		return base + 2;
	};
}
var y1 = make_yielder(10)();
if (resume y1 != 10) { panic "make_yielder 10"; }
if (resume y1 != 11) { panic "make_yielder 11"; }
if (resume y1 != 12) { panic "make_yielder 12"; }
var y2 = make_yielder(100)();
if (resume y2 != 100) { panic "make_yielder 100"; }
if (resume y2 != 101) { panic "make_yielder 101"; }
if (resume y2 != 102) { panic "make_yielder 102"; }

// Anonymous coroutine capturing mutable closure state across yields
fn make_counter_co(start: Int) -> co () -> co [Int, Nil, Int] {
	var cur = start;
	return co () -> (Int, Nil, Int) {
		while (true) {
			yield cur;
			cur += 1;
		}
		return -1;
	};
}
var cc = make_counter_co(20)();
if (resume cc != 20) { panic "counter_co 20"; }
if (resume cc != 21) { panic "counter_co 21"; }
if (resume cc != 22) { panic "counter_co 22"; }

// Higher-order: function receiving anonymous coroutine and driving it
fn run_to_done(c: co () -> co [Int, Nil, Int]) -> Int {
	var handle = c();
	var last = resume handle;
	// first yield already consumed, drive to return
	last = resume handle;
	return last;
}
var run_result = run_to_done(co () -> (Int, Nil, Int) { yield 1; return 99; });
if (run_result != 99) { panic "run_to_done 99"; }

// Anonymous coroutine factory capturing string
fn make_str_yielder(s: String) -> co () -> co [String, Nil, String] {
	return co () -> (String, Nil, String) {
		yield s;
		return s ++ "!";
	};
}
var sy = make_str_yielder("hello")();
if (resume sy != "hello") { panic "str yielder hello"; }
if (resume sy != "hello!") { panic "str yielder hello!"; }

// Multiple anonymous coroutines independent handles
var shared_gen = co (n: Int) -> (Int, Nil, Int) {
	yield n;
	yield n * 2;
	return n * 3;
};
var h1 = shared_gen(2);
var h2 = shared_gen(5);
if (resume h1 != 2) { panic "shared h1 2"; }
if (resume h2 != 5) { panic "shared h2 5"; }
if (resume h1 != 4) { panic "shared h1 4"; }
if (resume h2 != 10) { panic "shared h2 10"; }
if (resume h1 != 6) { panic "shared h1 6"; }
if (resume h2 != 15) { panic "shared h2 15"; }

// Anonymous coroutine returning immediately after a yield
var immediate = co () -> (Int, Nil, Int) { yield 1; return 42; };
var im = immediate();
if (resume im != 1) { panic "immediate yield 1"; }
if (resume im != 42) { panic "immediate 42"; }

// Coroutine with single yield then return, checked via resume values
var single_yield = co () -> (Int, Nil, Int) { yield 1; return 2; };
var sy_handle = single_yield();
if (resume sy_handle != 1) { panic "single yield 1"; }
if (resume sy_handle != 2) { panic "single final 2"; }
