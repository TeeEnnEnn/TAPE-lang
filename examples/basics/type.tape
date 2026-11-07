// Type aliases are transparent: `Number` resolves to the union Int | Float.
// Any member of the union is accepted wherever the alias is expected.

type Number = Int | Float;

var a: Number = 12;
var b: Number = 1.24;

// Alias in parameter position: call sites pass plain union members
fn pass_through(x: Number) -> Number {
	return x;
}

var p1: Number = pass_through(12);
var p2: Number = pass_through(1.24);

// Alias in return position: any member can flow out of the function
fn as_number(x: Int) -> Number {
	return x;
}

var r1: Number = as_number(7);

// Alias of an alias flattens to the same underlying type
type MyNumber = Number;

var m: MyNumber = 5;
var m2: MyNumber = pass_through(2.5);
