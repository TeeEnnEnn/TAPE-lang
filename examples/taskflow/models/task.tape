// The single-task view: a struct with behaviour, plus free functions so
// that other modules can work with tasks without calling methods across
// module boundaries.
use label_for_status_code, is_done_code from "./task_status.tape";
use label_for_priority_code from "./priority.tape";

pub struct Task {
    title: String,
    owner: String,
    estimate: Int,
    status_code: Int,
    priority_code: Int,
    flags: Int,
    fn summary() -> String {
        return self.title ++ " [" ++ label_for_status_code(self.status_code) ++ "]";
    }
    fn is_done() -> Bool {
        return is_done_code(self.status_code);
    }
    fn effort() -> String {
        if (self.estimate > 20) {
            return "huge";
        }
        if (self.estimate > 8) {
            return "large";
        }
        if (self.estimate > 3) {
            return "medium";
        }
        return "small";
    }
    fn owner_tag() -> String {
        return self.owner ++ "/" ++ label_for_priority_code(self.priority_code);
    }
}

pub fn make_task(title: String, owner: String, estimate: Int, status_code: Int, priority_code: Int, flags: Int) -> Task {
    return new Task { title = title, owner = owner, estimate = estimate, status_code = status_code, priority_code = priority_code, flags = flags };
}

pub fn task_summary(t: Task) -> String {
    return t.summary();
}

pub fn task_is_done(t: Task) -> Bool {
    return t.is_done();
}

pub fn task_effort(t: Task) -> String {
    return t.effort();
}

pub fn task_owner_tag(t: Task) -> String {
    return t.owner_tag();
}
