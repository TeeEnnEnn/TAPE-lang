struct Empty {}

struct Point {
	x: Int,
	y: Int,
}

struct Point3D {
	x: Int,
	y: Int,
	z: Int,

	fn print() -> Nil {
		self.x;
		self.y;
		self.z;
	}
}

struct Rect {
	width: Int,
	height: Int,

	fn area() -> Int {
		return self.width * self.height;
	}

	fn perimeter() -> Int {
		return 2 * (self.width + self.height);
	}

	fn is_square() -> Bool {
		return self.width == self.height;
	}

	fn scale(factor: Int) -> Rect {
		return new Rect { width = self.width * factor, height = self.height * factor };
	}

	fn describe() -> Int {
		return self.area() + self.perimeter();
	}
}

struct Line {
	start: Point,
	end: Point,
}

struct Label {
	text: String,
	reps: Int,
}

var e = new Empty{};

var p = new Point { x = 123, y = 235 };
var p3d = new Point3D { x = 234, y = 256, z = 111 };
var rect = new Rect { width = 4, height = 5 };
var label = new Label { text = "hello", reps = 3 };

if (p.x != 123) { panic "p.x"; }
if (p.y != 235) { panic "p.y"; }
if (p3d.z != 111) { panic "p3d.z"; }
if (label.text != "hello") { panic "label.text"; }
if (label.reps != 3) { panic "label.reps"; }

p3d.print();
if (rect.area() != 20) { panic "area"; }
if (rect.perimeter() != 18) { panic "perimeter"; }
if (rect.is_square() != false) { panic "is_square false"; }

var big = rect.scale(2);
if (big.area() != 80) { panic "big area"; }
if (big.perimeter() != 36) { panic "big perimeter"; }

if (rect.describe() != 38) { panic "describe"; }

if (rect.scale(3).area() != 180) { panic "scale area"; }
if (new Rect { width = 6, height = 6 }.is_square() != true) { panic "is_square true"; }

var line = new Line { start = new Point { x = 1, y = 2 }, end = new Point { x = 10, y = 20 } };
if (line.start.x != 1) { panic "line.start.x"; }
if (line.end.y != 20) { panic "line.end.y"; }

var sq = new Rect { width = 3, height = 3 };
if (sq.is_square() != true) { panic "sq is_square"; }
if (rect.is_square() != false) { panic "rect is_square"; }

if ((new Point { x = 7, y = 8 }).x != 7) { panic "anon point"; }
