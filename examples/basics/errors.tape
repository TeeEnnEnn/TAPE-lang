error TestError {
	BadState,
	WorseState,
	WorstState
}

var e1 = TestError::BadState;
var e2 = TestError::WorseState;
var e3 = TestError::WorstState;
