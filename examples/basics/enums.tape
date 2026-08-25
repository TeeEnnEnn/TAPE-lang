enum Weekdays {
	MONDAY,
	TUESDAY,
	WEDNESDAY,
	THURSDAY,
	FRIDAY,
	SATURDAY,
	SUNDAY
}

var a = Weekdays::MONDAY;
var b = Weekdays::TUESDAY;
var c = Weekdays::WEDNESDAY;
var d = Weekdays::THURSDAY;
var e = Weekdays::FRIDAY;
var f = Weekdays::SATURDAY;
var g = Weekdays::SUNDAY;

if (a != Weekdays::MONDAY) { panic "a"; }
if (b != Weekdays::TUESDAY) { panic "b"; }
if (c != Weekdays::WEDNESDAY) { panic "c"; }
if (d != Weekdays::THURSDAY) { panic "d"; }
if (e != Weekdays::FRIDAY) { panic "e"; }
if (f != Weekdays::SATURDAY) { panic "f"; }
if (g != Weekdays::SUNDAY) { panic "g"; }

if (a == b) { panic "a != b"; }
if (f == g) { panic "f != g"; }

var check = Weekdays::MONDAY;
if (check != Weekdays::MONDAY) { panic "check"; }
check = Weekdays::SUNDAY;
if (check != Weekdays::SUNDAY) { panic "check reassign"; }

enum Color { RED, GREEN, BLUE }
var col = Color::RED;
if (col != Color::RED) { panic "col red"; }
col = Color::BLUE;
if (col == Color::GREEN) { panic "col not green"; }
if (col != Color::BLUE) { panic "col blue"; }
