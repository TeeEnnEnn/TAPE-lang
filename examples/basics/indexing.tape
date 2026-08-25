var arr = [1, 2, 3, 4, 5];
var str = "This is 🔥 a test";
var tup  = ("a", 2, 3.3);
var tab = {"a": 1, "b":2};

if (arr[2] != 3) { panic "arr[2]"; }
if (arr[0] != 1) { panic "arr[0]"; }
if (arr[4] != 5) { panic "arr[4]"; }

if (str[0] != "T") { panic "str[0]"; }
if (str[8] != "🔥") { panic "str[8] fire"; }
if (str[10] != "a") { panic "str[10]"; }

if (tup.0 != "a") { panic "tup.0"; }
if (tup.1 != 2) { panic "tup.1"; }
if (tup.2 != 3.3) { panic "tup.2"; }

if (tab["a"] != 1) { panic "tab a"; }
if (tab["b"] != 2) { panic "tab b"; }

var nested_arr = [[1, 2], [3, 4], [5, 6]];
if (nested_arr[0][1] != 2) { panic "nested 0,1"; }
if (nested_arr[2][0] != 5) { panic "nested 2,0"; }

var t2 = (10, 20, 30);
if (t2.2 != 30) { panic "t2.2"; }

var s = "hello";
if (s[1] != "e") { panic "s[1]"; }
if (s[4] != "o") { panic "s[4]"; }

var mtab = { "x": [1,2], "y": [3,4] };
if (mtab["x"][0] != 1) { panic "mtab"; }
