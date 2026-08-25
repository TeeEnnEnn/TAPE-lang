var x = 1;
if (x != 1) { panic "x"; }
{
    var y = 2;
    if (y != 2) { panic "y"; }
    var z = x + y;
    if (z != 3) { panic "z"; }
    if (x != 1) { panic "x unchanged"; }
}
{
    var w = 100;
    if (w != 100) { panic "w"; }
}

var outer = 10;
{
    var inner = outer + 5;
    if (inner != 15) { panic "inner"; }
}
if (outer != 10) { panic "outer unchanged after block"; }

{
    var a = 5;
    {
        var b = 10;
        var c = a + b;
        if (c != 15) { panic "nested c"; }
        if (a != 5) { panic "a in nested"; }
    }
    if (a != 5) { panic "a after nested"; }
}

var shadow = 1;
{
    var shadow = 2;
    if (shadow != 2) { panic "shadow inner"; }
}
if (shadow != 1) { panic "shadow outer"; }

var counter = 0;
{
    counter = 5;
    if (counter != 5) { panic "counter inner"; }
}
if (counter != 5) { panic "counter outer mutated"; }
