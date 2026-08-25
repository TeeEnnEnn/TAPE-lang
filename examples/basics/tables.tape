var empty: Table[String, Int] = {};
var a: Table[Int, Int] = {};

var t1 = {1: nil};
if (t1[1] != nil) { panic "t1 nil"; }

var t2 = {1: "1"};
if (t2[1] != "1") { panic "t2"; }

var nested = {0:{0:{0: 42}}};
var inner = nested[0];
var innermost = inner[0];
if (innermost[0] != 42) { panic "nested"; }

var m = {"a": 1, "b": 2, "c": 3};
if (m["a"] != 1) { panic "m a"; }
if (m["b"] != 2) { panic "m b"; }
if (m["c"] != 3) { panic "m c"; }

var t = {"x": 10, "y": 20};
if (t["y"] != 20) { panic "t y"; }

var mixed: Table[String, String] = {"hello": "world"};
if (mixed["hello"] != "world") { panic "mixed"; }

var with_int_keys = {10: "ten", 20: "twenty"};
if (with_int_keys[10] != "ten") { panic "int key"; }
if (with_int_keys[20] != "twenty") { panic "int key 20"; }

var empty2: Table[String, Int] = {};
var t3 = {"a": 1};
if (t3["a"] != 1) { panic "t3 a"; }
