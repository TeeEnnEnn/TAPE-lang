// Aggregate statistics over a `TaskStore`: completion, estimates,
// per-owner load and a qualitative health verdict.
use TaskStore, store_count from "./task_store.tape";
use TaskError from "../models/task_error.tape";
use DONE_CODE from "../models/task_status.tape";
use percent_of from "../utils/math_utils.tape";
use count_by_status from "./task_filters.tape";

pub fn done_count(s: TaskStore) -> Int {
    return count_by_status(s, DONE_CODE);
}

pub fn open_count(s: TaskStore) -> Int {
    return store_count(s) - done_count(s);
}

pub fn completion_percent(s: TaskStore) -> Int {
    return percent_of(done_count(s), store_count(s));
}

pub fn open_estimate_total(s: TaskStore) -> Int {
    var total = 0;
    for (var i in 0..s.count) {
        if (s.status_codes[i] != DONE_CODE) {
            total += s.estimates[i];
        }
    }
    return total;
}

pub fn min_max_estimate(s: TaskStore) -> (Int, Int) {
    if (s.count == 0) {
        return (0, 0);
    }
    var lo = s.estimates[0];
    var hi = s.estimates[0];
    for (var i in 1..s.count) {
        if (s.estimates[i] < lo) {
            lo = s.estimates[i];
        }
        if (s.estimates[i] > hi) {
            hi = s.estimates[i];
        }
    }
    return (lo, hi);
}

pub fn owner_load(s: TaskStore, name: String) -> Int {
    var total = 0;
    for (var i in 0..s.count) {
        if (s.owners[i] == name) {
            total += s.estimates[i];
        }
    }
    return total;
}

pub fn load_table(s: TaskStore) -> Table[String, Int] {
    var m = {"ada": 0, "grace": 0, "linus": 0};
    m["ada"] = owner_load(s, "ada");
    m["grace"] = owner_load(s, "grace");
    m["linus"] = owner_load(s, "linus");
    return m;
}

pub fn busiest_owner(s: TaskStore) -> String {
    var best = "ada";
    if (owner_load(s, "grace") > owner_load(s, best)) {
        best = "grace";
    }
    if (owner_load(s, "linus") > owner_load(s, best)) {
        best = "linus";
    }
    return best;
}

pub fn health_verdict(s: TaskStore) -> String {
    var pct = completion_percent(s);
    if (pct >= 80) {
        return "healthy";
    }
    if (pct >= 40) {
        return "steady";
    }
    return "behind";
}
