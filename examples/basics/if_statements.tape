var r1 = 0;
if (true) {
	r1 = 1;
}
if (r1 != 1) { panic "r1"; }

var r2 = 0;
if (false) {
	r2 = 2;
}
if (r2 != 0) { panic "r2 false"; }

var r3 = 0;
if (true) {
	r3 = 3;
} else {
	r3 = 4;
}
if (r3 != 3) { panic "r3 else"; }

var r4 = 0;
if (false) {
	r4 = 5;
}else {
	r4 = 6;
}
if (r4 != 6) { panic "r4"; }

var r5 = 0;
if (false) {
	r5 = 7;
} else if (true) {
	r5 = 8;
}
if (r5 != 8) { panic "r5 else if"; }

var r6 = 0;
if (false) {
	r6 = 9;
} else if (false) {
	r6 = 10;
} else{
	r6 = 11;
}
if (r6 != 11) { panic "r6 else else"; }

var x = 10;
var y = 0;
if (x > 5) {
	y = 100;
} else {
	y = 200;
}
if (y != 100) { panic "x>5"; }

var a = 3;
var res = 0;
if (a == 1) {
	res = 10;
} else if (a == 2) {
	res = 20;
} else if (a == 3) {
	res = 30;
} else {
	res = 40;
}
if (res != 30) { panic "a==3"; }

var cond = true and false or true;
var out = 0;
if (cond) {
	out = 1;
}
if (out != 1) { panic "cond true"; }

var nested = 0;
if (true) {
	if (false) {
		nested = 1;
	} else {
		nested = 2;
	}
}
if (nested != 2) { panic "nested"; }
