const integer = 123;
const floating = 123.123;
const string = "hello world";
var arr = [1, 2, 3];
var tab = {1: "one", 2: "two", 3: "three"};
var tup = (1, "two", 12.3);

if (integer != 123) { panic "integer"; }
if (floating != 123.123) { panic "floating"; }
if (string != "hello world") { panic "string"; }

if (arr[0] != 1) { panic "arr[0]"; }
if (arr[1] != 2) { panic "arr[1]"; }
if (arr[2] != 3) { panic "arr[2]"; }

if (tab[1] != "one") { panic "tab 1"; }
if (tab[2] != "two") { panic "tab 2"; }
if (tab[3] != "three") { panic "tab 3"; }

if (tup.0 != 1) { panic "tup.0"; }
if (tup.1 != "two") { panic "tup.1"; }
if (tup.2 != 12.3) { panic "tup.2"; }

var combined = (integer + 1) * 2;
if (combined != 248) { panic "combined"; }

var str2 = string ++ "!";
if (str2 != "hello world!") { panic "str2"; }

var nested_arr = [[1, 2], [3, 4]];
if (nested_arr[1][0] != 3) { panic "nested_arr"; }

var nested_tup = (1, (2, 3));
var inner_tup = nested_tup.1;
if (inner_tup.1 != 3) { panic "nested_tup"; }
