// GC stress: string allocation churn.
//
// Each iteration produces a *unique* string (the accumulator grows),
// which defeats string interning so every iteration allocates a new
// ObjectString + char buffer on the managed heap. The previous
// accumulator value becomes garbage each iteration.
// ~2500 iterations ~= 3MB of char data, well past the 1MB initial
// GC threshold, so collection runs mid-script.

var s = "";
var i = 0;
while (i < 2500) {
	s = s ++ "x";
	i += 1;
}
var t = "seed";
var k = 0;
while (k < 1500) { t = t ++ "yz"; k += 1; }
if (s[0] != "x") { panic "gc strings head"; }
if (s[2499] != "x") { panic "gc strings tail"; }

"gc strings done";
