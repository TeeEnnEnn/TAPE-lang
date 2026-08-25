var x = 2 + 3 * 4;
var y = x + 1;

if (x != 14) { panic "x"; }
if (y != 15) { panic "y"; }

var abc = 10;
var abc2 = abc * 2;
if (abc2 != 20) { panic "abc2"; }

var _underscore = 5;
if (_underscore != 5) { panic "underscore"; }

var camelCase = 100;
var result = camelCase + y;
if (result != 115) { panic "camelCase"; }

var a1 = 1;
var a2 = a1 + 1;
var a3 = a2 + a1;
if (a3 != 3) { panic "a3"; }

y = 20;
if (y != 20) { panic "y mutated"; }
if (x != 14) { panic "x unchanged"; }
