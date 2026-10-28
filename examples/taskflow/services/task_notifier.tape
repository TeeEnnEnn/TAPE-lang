// Human-readable one-liners for tasks and headers.
use APP_NAME from "../config.tape";
use banner_str, quoted_str, tag_pair from "../utils/string_utils.tape";
use label_for_status_code from "../models/task_status.tape";

pub fn header_block() -> String {
    return banner_str(APP_NAME);
}

pub fn task_line(title: String, owner: String, code: Int) -> String {
    return "- " ++ quoted_str(title) ++ " " ++ tag_pair("owner", owner) ++ " " ++ tag_pair("status", label_for_status_code(code));
}

pub fn done_message(title: String) -> String {
    return "DONE " ++ quoted_str(title);
}
