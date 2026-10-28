error TestError {
	BadState,
	WorseState,
	WorstState
}

var e1 = TestError.BadState;
var e2 = TestError.WorseState;
var e3 = TestError.WorstState;

if (e1 != TestError.BadState) { panic "e1"; }
if (e2 != TestError.WorseState) { panic "e2"; }
if (e3 != TestError.WorstState) { panic "e3"; }

if (e1 == e2) { panic "e1 != e2"; }
if (e2 == e3) { panic "e2 != e3"; }

var check = TestError.BadState;
if (check != TestError.BadState) { panic "check"; }
check = TestError.WorstState;
if (check != TestError.WorstState) { panic "check reassign"; }
if (check == TestError.BadState) { panic "check not bad"; }

error SimpleError { NotFound, PermissionDenied }
var s1 = SimpleError.NotFound;
var s2 = SimpleError.PermissionDenied;
if (s1 == s2) { panic "s1 != s2"; }
if (s1 != SimpleError.NotFound) { panic "s1 notfound"; }
if (s2 != SimpleError.PermissionDenied) { panic "s2 perm"; }
