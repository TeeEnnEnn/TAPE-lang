while (false) {}

var test = 0;

while (true) {
	if (test == 5) {
		break;
	}
	test += 1;
}

test = 0;

while (test < 10) {
	test += 1;
	if (test % 2 == 0) {
		continue;
	}
	test;
}

var sum = 0;
for (var i in 0..10) {
    if (i == 3) continue; // Skips 3
    if (i == 8) break;    // Stops at 8
    sum += i;
}

// Standalone range variable:
var r = 10..0; // Descending!
for (var x in r) {
    sum += x;
}

sum;
"got here";
