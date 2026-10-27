// Lifecycle states for a task, plus helpers shared by many modules.
//
// Statuses travel between modules in two shapes: as `TaskStatus` enum
// values (for single-task APIs) and as plain `Int` codes (for bulk
// storage inside `TaskStore`, which keeps parallel arrays).
pub const TODO_CODE = 0;
pub const DOING_CODE = 1;
pub const DONE_CODE = 2;

pub enum TaskStatus {
    Todo,
    Doing,
    Done
}

pub fn status_code(s: TaskStatus) -> Int {
    return match (s) {
        TaskStatus.Todo => give 0;,
        TaskStatus.Doing => give 1;,
        TaskStatus.Done => give 2;
    };
}

pub fn status_label(s: TaskStatus) -> String {
    return match (s) {
        TaskStatus.Todo => give "todo";,
        TaskStatus.Doing => give "doing";,
        TaskStatus.Done => give "done";
    };
}

pub fn label_for_status_code(code: Int) -> String {
    if (code == TODO_CODE) {
        return "todo";
    }
    if (code == DOING_CODE) {
        return "doing";
    }
    return "done";
}

pub fn is_done_code(code: Int) -> Bool {
    return code == DONE_CODE;
}

pub fn is_done_status(s: TaskStatus) -> Bool {
    return s == TaskStatus.Done;
}
