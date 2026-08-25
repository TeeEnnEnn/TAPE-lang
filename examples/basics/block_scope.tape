var x = 1;
if (x != 1) { panic "x init"; }
{
    var y = 2;
    if (y != 2) { panic "y inner"; }
    var z = x + y;
    if (z != 3) { panic "z inner"; }
    if (x != 1) { panic "x not shadowed"; }
}
{
    var w = 100;
    if (w != 100) { panic "w second block"; }
    var x = 50;
    if (x != 50) { panic "x shadowed in second block"; }
}
if (x != 1) { panic "x outer unchanged"; }

var outer = 10;
{
    var inner = outer + 5;
    if (inner != 15) { panic "inner uses outer"; }
    outer = 20;
    if (inner != 15) { panic "inner not affected"; }
}
if (outer != 20) { panic "outer mutated inside"; }

{
    var a = 1;
    {
        var b = 2;
        {
            var c = a + b;
            if (c != 3) { panic "nested c"; }
        }
        if (b != 2) { panic "b mid"; }
    }
    if (a != 1) { panic "a outer"; }
}
