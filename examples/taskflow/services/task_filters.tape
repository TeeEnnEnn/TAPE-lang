// Read-only queries over a `TaskStore`: status tallies, flag tallies,
// owner lookups and the first open slot.
use TaskStore from "./task_store.tape";
use TaskError from "../models/task_error.tape";
use DONE_CODE from "../models/task_status.tape";
use FLAG_URGENT, FLAG_BLOCKED, has_task_flag from "../utils/task_flags.tape";

pub fn count_by_status(s: TaskStore, code: Int) -> Int {
    var n = 0;
    for (var i in 0..s.count) {
        if (s.status_codes[i] == code) {
            n += 1;
        }
    }
    return n;
}

pub fn count_urgent(s: TaskStore) -> Int {
    var n = 0;
    for (var i in 0..s.count) {
        if (has_task_flag(s.flags[i], FLAG_URGENT)) {
            n += 1;
        }
    }
    return n;
}

pub fn count_blocked(s: TaskStore) -> Int {
    var n = 0;
    for (var i in 0..s.count) {
        if (has_task_flag(s.flags[i], FLAG_BLOCKED)) {
            n += 1;
        }
    }
    return n;
}

pub fn has_owner_task(s: TaskStore, name: String) -> Bool {
    var i = 0;
    while (i < s.count) {
        if (s.owners[i] == name) {
            return true;
        }
        i += 1;
    }
    return false;
}

pub fn first_open_slot(s: TaskStore) -> Int | TaskError {
    var i = 0;
    while (i < s.count) {
        if (s.status_codes[i] != DONE_CODE) {
            return i + 1;
        }
        i += 1;
    }
    return TaskError.NotFound;
}
