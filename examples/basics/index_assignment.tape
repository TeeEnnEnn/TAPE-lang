var values: Array[Int] = [1, 2, 3];
values[0] = 10;
values[1] += 5;
if (values[0] != 10) { panic "array index assignment"; }
if (values[1] != 7) { panic "array compound index assignment"; }

var counts: Table[String, Int] = { "apples": 1 };
counts["apples"] += 2;
counts["oranges"] = 4;
if (counts["apples"] != 3) { panic "table compound index assignment"; }
if (counts["oranges"] != 4) { panic "table index assignment"; }
