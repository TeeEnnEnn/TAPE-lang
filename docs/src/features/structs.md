# Structs

This page covers struct fields, methods, and creating struct values.

## Defining a struct

A struct groups fields into a value. Fields are private by default. Add `pub` to a field when code outside the struct should be able to read or write it.

```TAPE
pub struct Point {
    pub x: Int,
    pub y: Int
}
```

The struct itself is public here, so another module can import the type. The fields are public separately, so code using an imported `Point` can access them.

## Creating a struct

Use `new` and name the fields being initialized:

```TAPE
var point = new Point { x = 3, y = 4 };
```

Every field without a default value must be initialized. Fields with defaults may be left out:

```TAPE
struct Counter {
    value: Int = 0
}

var counter = new Counter {};
```

Defaults on exported structs must be literal values, since the default is copied into each importing module.

Code outside a struct can only initialize its public fields. A method of the declaring struct can initialize private fields too. This is useful when a struct should control how its values are made.

## Instance methods

An instance method declares its receiver explicitly as the first parameter, using the name `self` without a type annotation:

```TAPE
pub struct Rect {
    pub width: Int,
    pub height: Int,

    pub fn area(self) -> Int {
        return self.width * self.height;
    }
}
```

Call an instance method through a value:

```TAPE
var rect = new Rect { width = 4, height = 5 };
var area = rect.area();
```

The compiler infers that `self` has type `Rect` and passes `rect` as the receiver. `self` must be the first parameter and cannot have a type annotation. A method without `self` does not get an instance receiver automatically.

## Associated functions

A struct function without `self` is an associated function. Call it through the struct type instead of an instance:

```TAPE
pub struct Box {
    secret: Int,

    pub fn create(value: Int) -> Box {
        return new Box { secret = value };
    }

    pub fn value(self) -> Int {
        return self.secret;
    }
}

var box = Box.create(7);
var value = box.value();
```

`create` can initialize `secret` because it is declared inside `Box`. Code outside `Box` cannot access or initialize that private field directly. It can still use the public factory and public instance method.

An instance method is called on a value, and an associated function is called on the type. These call forms are checked: `Box.value()` cannot call an instance method, and `box.create()` cannot call an associated function.

## Visibility

Struct visibility and member visibility are separate. The struct must be `pub` to be imported, and each field or function must be `pub` to be used from outside the declaring struct. Private fields and functions remain available inside methods of their declaring struct, including associated functions.

Public function signatures must use public types. For example, a public function on a public struct cannot expose a private struct type in its parameters or return type.
