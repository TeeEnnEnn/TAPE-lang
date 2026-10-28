use PI, add from "math.tape";

var res = add(PI, 1.0);
// NOTE: 3.14 is not exactly representable in binary, so compare in a
// window rather than with ==.
if (res < 4.13 or res > 4.15) { panic "import failed"; }
