var x = 2 + 3 * 4;
const y = 42;

if (x != 14) { panic "x"; }
if (y != 42) { panic "y"; }

x = 100;
if (x != 100) { panic "x mutated"; }
if (y != 42) { panic "y still 42"; }

var a = 1;
var b = a + 41;
if (b != 42) { panic "b"; }

const z = y + x;
if (z != 142) { panic "z"; }

pub const pub_const = 456;
if (pub_const != 456) { panic "pub_const"; }
var pub_var = 123;
if (pub_var != 123) { panic "pub_var"; }
pub_var = 789;
if (pub_var != 789) { panic "pub_var mutated"; }
