// Deferred actions run in reverse registration order when the current scope exits.
fn make_value() -> Array[Int] {
	var values = [0];
	defer { values[0] = values[0] * 10 + 1; }
	defer { values[0] = values[0] * 10 + 2; }
	return values;
}

if (make_value()[0] != 21) { panic "defer LIFO order"; }

error ReadError { Missing }

fn fail() -> ReadError!Int {
	return ReadError.Missing;
}

fn use_errdefer() -> Array[Int] {
	var result = [0];
	fn inner() -> ReadError!Int {
		errdefer { result[0] = 1; }
		return try fail();
	}
	var ignored = inner() catch 0;
	return result;
}

if (use_errdefer()[0] != 1) { panic "errdefer on error propagation"; }
