fn basic_test() -> Nil{
	12;
}

fn param_test(a: Int) -> Nil {
	a;
}

fn multiple_params(a: Int, b: Float) -> Nil {
	a;
	b;
}

fn variable_param_test(a: Int) -> Nil {
	a;
}

fn with_return(a: Int) -> Int {
	return a * 5;
}

fn with_locals() -> Int {
	var a = "test";
	var len = a[2];
	var b = 134;
	return b - 100;
}

fn make_counter() -> fn () -> Int {
	var counter = 0;

	fn increment() -> Int {
		counter += 1;
		return counter;
	}

	return increment;
}

fn add(a: Int, b: Int) -> Int {
	return a + b;
}

fn mul(a: Int, b: Int) -> Int {
	return a * b;
}

fn factorial(n: Int) -> Int {
	if (n <= 1) {
		return 1;
	}
	return n * factorial(n - 1);
}

basic_test();
param_test(24);
multiple_params(1, 2.3);
var number: Int = 13;
variable_param_test(number);

if (with_return(5) != 25) { panic "with_return 5"; }
if (with_return(0) != 0) { panic "with_return 0"; }
if (with_return(3) != 15) { panic "with_return 3"; }

var wl = with_locals();
if (wl != 34) { panic "with_locals"; }

var inc = make_counter();
if (inc() != 1) { panic "inc 1"; }
if (inc() != 2) { panic "inc 2"; }
if (inc() != 3) { panic "inc 3"; }

var inc2 = make_counter();
if (inc2() != 1) { panic "inc2 1"; }
if (inc() != 4) { panic "inc 4 separate"; }

if (add(2, 3) != 5) { panic "add"; }
if (mul(3, 4) != 12) { panic "mul"; }
if (factorial(5) != 120) { panic "factorial 5"; }
if (factorial(1) != 1) { panic "factorial 1"; }
if (factorial(0) != 1) { panic "factorial 0"; }

var adder = add;
if (adder(10, 20) != 30) { panic "adder fn var"; }
