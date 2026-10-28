// Bit flags attached to tasks. Stored as plain integers so they can live
// in bulk arrays; inspected with bitwise operators.
pub const FLAG_URGENT = 1;
pub const FLAG_BLOCKED = 2;

pub fn has_task_flag(flags: Int, bit: Int) -> Bool {
    return (flags & bit) != 0;
}

pub fn set_task_flag(flags: Int, bit: Int) -> Int {
    return flags | bit;
}

pub fn clear_task_flag(flags: Int, bit: Int) -> Int {
    return flags ^ (flags & bit);
}

pub fn flag_names(flags: Int) -> String {
    var out = "";
    if (has_task_flag(flags, FLAG_URGENT)) {
        out ++= "urgent";
    }
    if (has_task_flag(flags, FLAG_BLOCKED)) {
        if (out != "") {
            out ++= "+";
        }
        out ++= "blocked";
    }
    if (out == "") {
        return "none";
    }
    return out;
}
