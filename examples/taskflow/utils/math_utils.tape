// Small integer helpers used by stats, validators and the demo checks.
pub fn clamp_int(x: Int, lo: Int, hi: Int) -> Int {
    if (x < lo) {
        return lo;
    }
    if (x > hi) {
        return hi;
    }
    return x;
}

pub fn min_int(a: Int, b: Int) -> Int {
    if (a < b) {
        return a;
    }
    return b;
}

pub fn max_int(a: Int, b: Int) -> Int {
    if (a > b) {
        return a;
    }
    return b;
}

pub fn percent_of(part: Int, total: Int) -> Int {
    if (total == 0) {
        return 0;
    }
    return (part * 100) / total;
}

pub fn apply_to_estimate(x: Int, f: fn (Int) -> Int) -> Int {
    return f(x);
}
