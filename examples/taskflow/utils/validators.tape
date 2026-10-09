// Input validation shared by the store and the workflow helpers.
use MAX_TASKS, MAX_ESTIMATE from "../config.tape";
use clamp_int from "./math_utils.tape";

pub fn valid_estimate(hours: Int) -> Bool {
    return hours > 0 and hours <= MAX_ESTIMATE;
}

pub fn valid_slot(index: Int) -> Bool {
    return index >= 0 and index < MAX_TASKS;
}

pub fn valid_task_id(id: Int) -> Bool {
    return id >= 1 and id <= MAX_TASKS;
}

pub fn clamp_estimate(hours: Int) -> Int {
    return clamp_int(hours, 1, MAX_ESTIMATE);
}
