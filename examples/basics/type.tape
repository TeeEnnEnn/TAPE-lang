// Type aliases are transparent: `UserId` resolves to the underlying type.
// The alias and the underlying type are interchangeable.

type UserId = Int;

var a: UserId = 12;
var b: Int = a;

// Alias in parameter position: call sites pass plain values
fn pass_through(x: UserId) -> UserId {
	return x;
}

var p1: UserId = pass_through(12);
var p2: Int = pass_through(7);

// Alias in return position: the underlying type flows out unchanged
fn as_id(x: Int) -> UserId {
	return x;
}

var r1: UserId = as_id(7);
var r2: Int = as_id(9);

// Alias of an alias resolves to the same underlying type
type AccountId = UserId;

var m: AccountId = 5;
var m2: Int = pass_through(11);
