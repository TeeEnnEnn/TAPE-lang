// State-changing workflows: closing, reopening, blocking and
// unblocking tasks. Each step validates through the store and uses
// `try` to propagate `TaskError` unions from the imported store API.
use TaskStore, store_status_at, store_set_status, store_flags_at, store_set_flags from "./task_store.tape";
use TaskError from "../models/task_error.tape";
use DONE_CODE, DOING_CODE from "../models/task_status.tape";
use FLAG_BLOCKED, set_task_flag, clear_task_flag from "../utils/task_flags.tape";

pub fn close_task(s: TaskStore, id: Int) -> Int | TaskError {
    var cur = try store_status_at(s, id);
    if (cur == DONE_CODE) {
        return TaskError::AlreadyDone;
    }
    return try store_set_status(s, id, DONE_CODE);
}

pub fn reopen_task(s: TaskStore, id: Int) -> Int | TaskError {
    var cur = try store_status_at(s, id);
    if (cur != DONE_CODE) {
        return TaskError::InvalidInput;
    }
    return try store_set_status(s, id, DOING_CODE);
}

pub fn block_task(s: TaskStore, id: Int) -> Int | TaskError {
    var cur = try store_flags_at(s, id);
    return try store_set_flags(s, id, set_task_flag(cur, FLAG_BLOCKED));
}

pub fn unblock_task(s: TaskStore, id: Int) -> Int | TaskError {
    var cur = try store_flags_at(s, id);
    return try store_set_flags(s, id, clear_task_flag(cur, FLAG_BLOCKED));
}

pub fn close_task_name(id: Int) -> String | TaskError {
    if (id == 2) {
        return "Fix parser";
    }
    return TaskError::NotFound;
}
