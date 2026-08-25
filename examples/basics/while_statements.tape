var i = 0;
while (i < 3) {
	i += 1;
}
if (i != 3) { panic "while i<3"; }

var sum = 0;
var n = 1;
while (n <= 5) {
	sum += n;
	n += 1;
}
if (sum != 15) { panic "sum 1..5"; }

var countdown = 5;
while (countdown > 0) {
	countdown -= 1;
}
if (countdown != 0) { panic "countdown"; }

var executed = false;
var flag = true;
while (flag) {
	executed = true;
	flag = false;
}
if (executed != true) { panic "while flag"; }

var never = 0;
while (false) {
	never = 1;
}
if (never != 0) { panic "while false"; }

var nested_sum = 0;
var outer = 0;
while (outer < 2) {
	var inner = 0;
	while (inner < 2) {
		nested_sum += 1;
		inner += 1;
	}
	outer += 1;
}
if (nested_sum != 4) { panic "nested while"; }
