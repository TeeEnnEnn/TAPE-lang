if ((true and false) != false) { panic "and"; }
if ((false or true) != true) { panic "or"; }
if ((not false) != true) { panic "not false"; }
if ((not true) != false) { panic "not true"; }
if ((not true and false or true) != true) { panic "precedence"; }
if ((not not not false) != true) { panic "not not not"; }

var t = true;
var f = false;
if ((t and f) != false) { panic "t and f"; }
if ((t or f) != true) { panic "t or f"; }
if ((not t) != false) { panic "not t"; }
if ((t and not f) != true) { panic "t and not f"; }

var a = false or true and false;
if (a != false) { panic "or/and precedence"; }

var b = not false and true;
if (b != true) { panic "not and"; }

if ((true and true) != true) { panic "true and true"; }
if ((false and false) != false) { panic "false and false"; }
if ((false or false) != false) { panic "false or false"; }
