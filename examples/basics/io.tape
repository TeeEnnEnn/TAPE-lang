native fn io_print(msg: String) -> Nil;

struct Printer {
	pub fn print(msg: String) -> Nil {
		return io_print(msg);
	}
}

var p = new Printer {};

Printer.print("Hello, world!");
Printer.print("This is working!");
