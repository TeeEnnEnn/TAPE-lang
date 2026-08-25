var empty: Array[Int] = [];

var a = [1, 2, 3];
if (a[0] != 1) { panic "a[0]"; }
if (a[1] != 2) { panic "a[1]"; }
if (a[2] != 3) { panic "a[2]"; }

var nested = [[], [], []];
var first_nested = nested[0];

var nums = [10, 20, 30, 40];
if (nums[2] != 30) { panic "nums[2]"; }

var strs: Array[String] = ["a", "b", "c"];
if (strs[1] != "b") { panic "strs[1]"; }

var mixed = [1, 2];
mixed = [3, 4];
if (mixed[0] != 3) { panic "mixed reassigned"; }

var two_d = [[1, 2], [3, 4]];
if (two_d[0][1] != 2) { panic "two_d"; }
if (two_d[1][0] != 3) { panic "two_d 1,0"; }
