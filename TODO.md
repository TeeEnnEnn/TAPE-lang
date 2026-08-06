Things I need to do:

[ ] - Remove the ability for functions to capture global scope
	[ ] - Remove the ability for functions to capture global mutable state - allow constant state iff that state has the same visibility of the function
[ ] - use type checker statement termination to determine whether or not we need to add a return to a function call
