// Task priorities. Mirrors the status module: enum values for
// single-task APIs and `Int` codes for bulk storage in `TaskStore`.
pub const LOW_CODE = 0;
pub const MEDIUM_CODE = 1;
pub const HIGH_CODE = 2;
pub const URGENT_CODE = 3;

pub enum Priority {
    Low,
    Medium,
    High,
    Urgent
}

pub fn priority_rank(p: Priority) -> Int {
    return match (p) {
        Priority.Low => give 0;,
        Priority.Medium => give 1;,
        Priority.High => give 2;,
        Priority.Urgent => give 3;
    };
}

pub fn priority_label(p: Priority) -> String {
    return match (p) {
        Priority.Low => give "low";,
        Priority.Medium => give "medium";,
        Priority.High => give "high";,
        Priority.Urgent => give "urgent";
    };
}

pub fn label_for_priority_code(code: Int) -> String {
    if (code == LOW_CODE) {
        return "low";
    }
    if (code == MEDIUM_CODE) {
        return "medium";
    }
    if (code == HIGH_CODE) {
        return "high";
    }
    return "urgent";
}

pub fn is_urgent_code(code: Int) -> Bool {
    return code == URGENT_CODE;
}
