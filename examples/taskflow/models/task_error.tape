// Fallible operations in TaskFlow report one of these errors.
// Callers use `try` to propagate them and `match` to inspect them.
pub error TaskError {
    NotFound,
    StoreFull,
    InvalidInput,
    AlreadyDone
}

pub fn task_error_name(e: TaskError) -> String {
    return match (e) {
        TaskError.NotFound => give "not-found";,
        TaskError.StoreFull => give "store-full";,
        TaskError.InvalidInput => give "invalid-input";,
        TaskError.AlreadyDone => give "already-done";
    };
}
