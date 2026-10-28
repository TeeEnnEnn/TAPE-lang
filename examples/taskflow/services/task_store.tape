// Bulk task storage: parallel fixed-size arrays plus a logical length.
//
// Task ids are 1-based (`id = slot + 1`). Fallible accessors return
// `... | TaskError` unions; mutating helpers take the store struct and
// update it in place.
use MAX_TASKS from "../config.tape";
use TaskError from "../models/task_error.tape";
use valid_estimate, valid_task_id from "../utils/validators.tape";

pub struct TaskStore {
    pub titles: Array[String],
    pub owners: Array[String],
    pub estimates: Array[Int],
    pub status_codes: Array[Int],
    pub priority_codes: Array[Int],
    pub flags: Array[Int],
    pub count: Int,
    pub next_id: Int
}

pub fn make_task_store() -> TaskStore {
    return new TaskStore {
        titles = ["", "", "", "", "", "", "", ""],
        owners = ["", "", "", "", "", "", "", ""],
        estimates = [0, 0, 0, 0, 0, 0, 0, 0],
        status_codes = [0, 0, 0, 0, 0, 0, 0, 0],
        priority_codes = [0, 0, 0, 0, 0, 0, 0, 0],
        flags = [0, 0, 0, 0, 0, 0, 0, 0],
        count = 0,
        next_id = 1
    };
}

pub fn store_count(s: TaskStore) -> Int {
    return s.count;
}

pub fn store_add(s: TaskStore, title: String, owner: String, estimate: Int, status: Int, priority: Int, flag_bits: Int) -> Int | TaskError {
    if (s.count >= MAX_TASKS) {
        return TaskError.StoreFull;
    }
    if (valid_estimate(estimate) != true) {
        return TaskError.InvalidInput;
    }
    s.titles[s.count] = title;
    s.owners[s.count] = owner;
    s.estimates[s.count] = estimate;
    s.status_codes[s.count] = status;
    s.priority_codes[s.count] = priority;
    s.flags[s.count] = flag_bits;
    s.count += 1;
    s.next_id += 1;
    return s.next_id - 1;
}

pub fn store_slot_open(s: TaskStore, id: Int) -> Int | TaskError {
    if (valid_task_id(id) != true) {
        return TaskError.NotFound;
    }
    var slot = id - 1;
    if (slot >= s.count) {
        return TaskError.NotFound;
    }
    return slot;
}

pub fn store_title_at(s: TaskStore, id: Int) -> String | TaskError {
    var slot = try store_slot_open(s, id);
    return s.titles[slot];
}

pub fn store_owner_at(s: TaskStore, id: Int) -> String | TaskError {
    var slot = try store_slot_open(s, id);
    return s.owners[slot];
}

pub fn store_estimate_at(s: TaskStore, id: Int) -> Int | TaskError {
    var slot = try store_slot_open(s, id);
    return s.estimates[slot];
}

pub fn store_status_at(s: TaskStore, id: Int) -> Int | TaskError {
    var slot = try store_slot_open(s, id);
    return s.status_codes[slot];
}

pub fn store_priority_at(s: TaskStore, id: Int) -> Int | TaskError {
    var slot = try store_slot_open(s, id);
    return s.priority_codes[slot];
}

pub fn store_flags_at(s: TaskStore, id: Int) -> Int | TaskError {
    var slot = try store_slot_open(s, id);
    return s.flags[slot];
}

pub fn store_set_status(s: TaskStore, id: Int, code: Int) -> Int | TaskError {
    var slot = try store_slot_open(s, id);
    s.status_codes[slot] = code;
    return id;
}

pub fn store_set_flags(s: TaskStore, id: Int, flag_bits: Int) -> Int | TaskError {
    var slot = try store_slot_open(s, id);
    s.flags[slot] = flag_bits;
    return id;
}

pub fn store_total_estimate(s: TaskStore) -> Int {
    var total = 0;
    for (var i in 0..s.count) {
        total += s.estimates[i];
    }
    return total;
}

pub fn store_count_by_status(s: TaskStore, code: Int) -> Int {
    var n = 0;
    for (var i in 0..s.count) {
        if (s.status_codes[i] == code) {
            n += 1;
        }
    }
    return n;
}
