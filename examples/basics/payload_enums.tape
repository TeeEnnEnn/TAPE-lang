enum Loaded {
    variant_one: struct { f1: Int, f2: String },
    variant_two: Int,
    variant_three,
}

// Payload variants are constructed by calling the variant with its one payload value.
Loaded.variant_one(new { f1 = 12, f2 = "Hello" });
Loaded.variant_two(7);
Loaded.variant_three;

fn inspect(value: Loaded) -> Nil {
    match (value) {
        Loaded.variant_one => bind (record) { record.f1; },
        Loaded.variant_two => bind (number) { number; },
        Loaded.variant_three => {},
    };
}

inspect(Loaded.variant_one(new { f1 = 12, f2 = "Hello" }));
