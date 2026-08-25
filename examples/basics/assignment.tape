var x = 1;
if (x != 1) { panic "init"; }
x = 2;
if (x != 2) { panic "assign"; }
x += 1;
if (x != 3) { panic "+="; }
x -= 1;
if (x != 2) { panic "-="; }
x *= 2;
if (x != 4) { panic "*="; }
x /= 2;
if (x != 2) { panic "/="; }
x %= 2;
if (x != 0) { panic "%="; }
x = 2;
x **= 3;
if (x != 8) { panic "**="; }

var y = "test";
if (y != "test") { panic "y init"; }
y ++= " string";
if (y != "test string") { panic "++="; }
y = "hello" ++ " world";
if (y != "hello world") { panic "++"; }

var z = 10;
var w = z;
w += 5;
if (w != 15) { panic "w +=5"; }
if (z != 10) { panic "z unchanged"; }
