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

// multiples a number by five (WOW! So cool!)
fn with_return(a: Int) -> Int {
	return a * 5;
}

fn with_locals() -> Nil {
	var a = "test";
	a[2];
	var b = 134;
	b - 342;
}

fn make_counter() -> fn () -> Int {
	var counter = 0;

	fn test() -> Nil {
	}
	test();

	fn increment() -> Int {
		counter += 1;
		return counter;
	}

	return increment;
}

basic_test();
param_test(24);
multiple_params(1, 2.3);
var number: Int = 13;
variable_param_test(number);
with_return(5);
with_locals();

// TODO: This needs to be fixed - functions should not be allowed to access global state
var capture = 11;
fn attempt_capture() -> Int{
	return capture + 1;
}

attempt_capture();
