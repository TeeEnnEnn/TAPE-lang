Things I need to do:

[x] - 2026/10/05: move vm and isolate into their own files
[x] - 2026/10/05: stress gc

[ ] - 2026/10/06: squash gc safety bugs


[ ] - Remove the ability for functions to capture global scope
	[ ] - Remove the ability for functions to capture global mutable state - allow constant state iff that state has the same visibility of the function
[ ] - use type checker statement termination to determine whether or not we need to add a return to a function call
