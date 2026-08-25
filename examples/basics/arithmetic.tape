var a = 1 + 2 - 3 * 4 / 2 + (2 + 8);
if (a != 7) { panic "a precedence"; }

var b = -12 + 32 - -12;
if (b != 32) { panic "b double minus"; }

var c = -12 + 12 + 1;
if (c != 1) { panic "c"; }

if (4 % 3 != 1) { panic "4%3"; }
if (1.2 % 0.4 != 0.3999999999999999 - 0.0) { panic "mod float"; }
if (12 % 2.5 != 2.0) { panic "12%2.5"; }
if (2.5 % 1 != 0.5) { panic "2.5%1"; }

if (2 ** 4 != 16) { panic "2**4"; }
if (2 ** 0 != 1) { panic "2**0"; }
var v_pow = 3 ** 1.2;
if (v_pow < 3.7 or v_pow > 3.8) { panic "3**1.2"; }

var mixed_add = 1 + 1.5;
if (mixed_add != 2.5) { panic "mixed_add"; }
var mixed_sub = 5.5 - 2;
if (mixed_sub != 3.5) { panic "mixed_sub"; }
var mixed_mul = 2 * 1.5;
if (mixed_mul != 3.0) { panic "mixed_mul"; }
var mixed_div = 7.5 / 2;
if (mixed_div != 3.75) { panic "mixed_div"; }

var exp_int = 2 ** 3;
if (exp_int != 8) { panic "exp_int"; }
var exp_mixed = 4 ** 0.5;
if (exp_mixed != 2.0) { panic "exp_mixed"; }
