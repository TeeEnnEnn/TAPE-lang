# Importing

This page covers importing code between modules.

## Imports

Imports use the `use` keyword. The path names a TAPE file and is resolved relative to the file doing the importing.

```TAPE
use add from "math.tape";
```

This imports the exported name `add` from `math.tape`. You can import more than one name at a time:

```TAPE
use add, PI from "math.tape";
```

An alias gives an imported name a different name in the current module:

```TAPE
use add as plus from "math.tape";

var total = plus(2, 3);
```

The alias is the name used in this module. The original name is not also available unless you import it separately.

## Exports

A name must be exported before another module can import it. Use `pub` on the declaration:

```TAPE
pub const PI = 3.14;

pub fn add(a: Float, b: Float) -> Float {
    return a + b;
}
```

The names that can be exported are constants, functions, coroutines, structs, enums, errors, and type aliases. A module-level constant must have a literal value. Mutable module-level variables and top-level statements are not supported in imported modules; an imported module is for declarations, not for code that runs when it is loaded.

Types used in a public module-level function or coroutine signature must also be public. This lets an importing module name every type it needs to call that function.

## Re-exporting

`pub` and `use` can work together to re-export a name. This lets another module import it through the current module:

```TAPE
pub use add as plus from "math.tape";
```

Another module can now import `plus` from this module. The re-export keeps the original type and declaration, but makes it available under the imported name `plus`.

## Import paths

Relative paths are resolved from the importing file, so imports keep working when a module is used from a different entry point:

```TAPE
use label_for_status from "../models/task_status.tape";
```

`./` and `../` can be used to refer to files in the same directory or a parent directory. Absolute paths are also accepted.

## Example

Suppose `math.tape` contains:

```TAPE
pub const PI = 3.14;

pub fn add(a: Float, b: Float) -> Float {
    return a + b;
}
```

An entry module can import and use both names:

```TAPE
use add, PI from "math.tape";

var two_pi = add(PI, PI);
```

Importing a name that is not public, or defining a local name with the same name as an import, is an error.
