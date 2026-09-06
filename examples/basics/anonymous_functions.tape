// Simple anonymous function: no params, no capture
var unit = fn () -> Nil {
	return nil;
};
unit();

// Anonymous function with return value
var get_42 = fn () -> Int {
	return 42;
};
if (get_42() != 42) { panic "anon get_42"; }

// Anonymous function with params
var add = fn (a: Int, b: Int) -> Int {
	return a + b;
};
if (add(2, 3) != 5) { panic "anon add"; }
if (add(-1, 1) != 0) { panic "anon add neg"; }

// Stored in typed variable
var typed_add: fn (Int, Int) -> Int = fn (a: Int, b: Int) -> Int {
	return a + b;
};
if (typed_add(10, 20) != 30) { panic "typed anon add"; }

// Immediate invocation (IIFE)
var iife = fn (x: Int) -> Int { return x * 3; }(7);
if (iife != 21) { panic "iife"; }

// Higher-order: passing anonymous function as argument
fn apply(x: Int, f: fn (Int) -> Int) -> Int {
	return f(x);
}
var doubled = apply(5, fn (n: Int) -> Int { return n * 2; });
if (doubled != 10) { panic "apply anon"; }
var composed = apply(10, fn (n: Int) -> Int { return n + 5; });
if (composed != 15) { panic "apply anon +5"; }

// Function returning anonymous function (closure without capture)
fn make_greeter() -> fn () -> String {
	return fn () -> String {
		return "hi";
	};
}
var greeter = make_greeter();
if (greeter() != "hi") { panic "greeter"; }

// Closure capturing outer local (by-value capture of parent local)
fn make_adder(n: Int) -> fn (Int) -> Int {
	return fn (x: Int) -> Int {
		return x + n;
	};
}
var add5 = make_adder(5);
if (add5(10) != 15) { panic "add5 10"; }
if (add5(0) != 5) { panic "add5 0"; }
var add10 = make_adder(10);
if (add10(5) != 15) { panic "add10 5"; }
// Independent closures
if (add5(0) != 5) { panic "add5 still 5"; }
if (add10(0) != 10) { panic "add10 still 10"; }

// Closure capturing mutable state (counter)
fn make_counter_anon() -> fn () -> Int {
	var c = 0;
	return fn () -> Int {
		c += 1;
		return c;
	};
}
var counter = make_counter_anon();
if (counter() != 1) { panic "counter 1"; }
if (counter() != 2) { panic "counter 2"; }
if (counter() != 3) { panic "counter 3"; }
var counter2 = make_counter_anon();
if (counter2() != 1) { panic "counter2 1"; }
if (counter() != 4) { panic "counter 4 separate"; }

// Nested closures: outer returns middle which returns inner
fn outer_fn(x: Int) -> fn (Int) -> fn (Int) -> Int {
	return fn (y: Int) -> fn (Int) -> Int {
		return fn (z: Int) -> Int {
			return x + y + z;
		};
	};
}
var middle = outer_fn(10);
var inner = middle(20);
if (inner(30) != 60) { panic "nested closure 60"; }
if (outer_fn(1)(2)(3) != 6) { panic "triple nested"; }

// Anonymous function capturing multiple locals
fn multi_capture(a: Int, b: Int) -> fn () -> Int {
	var c = a + b;
	return fn () -> Int {
		return c * 2;
	};
}
var mc = multi_capture(3, 4);
if (mc() != 14) { panic "multi_capture"; }

// Anonymous function assigned and reassigned
var flex: fn (Int) -> Int = fn (x: Int) -> Int { return x; };
if (flex(99) != 99) { panic "flex identity"; }
flex = fn (x: Int) -> Int { return x * x; };
if (flex(5) != 25) { panic "flex square"; }

// Anonymous function used in expression context (argument to another anon)
var result = fn (f: fn (Int) -> Int, v: Int) -> Int { return f(v); }(fn (n: Int) -> Int { return n - 1; }, 10);
if (result != 9) { panic "anon as arg expression"; }

// Closure inside loop / multiple closures created with different captures
fn make_adders() -> fn (Int) -> Int {
	var base = 100;
	return fn (x: Int) -> Int {
		return base + x;
	};
}
var adder100 = make_adders();
if (adder100(1) != 101) { panic "adder100 1"; }
if (adder100(50) != 150) { panic "adder100 50"; }
