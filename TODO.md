Things I need to do:

[x] - 2026/10/05: move vm and isolate into their own files
[x] - 2026/10/05: stress gc

[x] - 2026/10/06: squash gc safety bugs

[ ] - 2026/10/09: multi module projects

[ ] - 2026/10/09: catch expression test script

~~[ ] - 2026/10/07: allow anonymous functions at declaration position~~
Will not be adding this. use (anon_fn)(); at the declaration position instead.

[ ] - Remove the ability for functions to capture global scope
	[ ] - Remove the ability for functions to capture global mutable state - allow constant state iff that state has the same visibility of the function
[ ] - use type checker statement termination to determine whether or not we need to add a return to a function call
