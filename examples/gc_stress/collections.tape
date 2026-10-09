// GC stress: array + table allocation churn.
//
// Every iteration allocates fresh collection objects (array header +
// elements, table header + entries array) that become garbage on the
// next iteration. ~6000 iterations at ~500B each ~= 3MB, well past
// the 1MB initial GC threshold. Exercises OP_ARRAY, OP_TABLE,
// table capacity growth, and indexing.

var i = 0;
while (i < 6000) {
	var a = [i, i + 1, i + 2, i + 3, i + 4, i + 5, i + 6, i + 7];
	if (a[0] != i) { panic "gc array head"; }
	if (a[7] != i + 7) { panic "gc array tail"; }

	var t = {1: i, 2: i + 1, 3: i + 2, 4: i + 3, 5: i + 4, 6: i + 5, 7: i + 6, 8: i + 7};
	if (t[1] != i) { panic "gc table head"; }
	if (t[8] != i + 7) { panic "gc table tail"; }

	// Index assignment on fresh objects exercises the write path too.
	a[0] = i * 2;
	if (a[0] != i * 2) { panic "gc array set"; }
	t[1] = i * 2;
	if (t[1] != i * 2) { panic "gc table set"; }

	i += 1;
}

"gc collections done";
