// Demo fixtures: a fixed set of users and tasks used by the entrypoint.
use TaskStore, store_add, store_count from "./task_store.tape";
use TODO_CODE, DOING_CODE from "../models/task_status.tape";
use LOW_CODE, MEDIUM_CODE, HIGH_CODE, URGENT_CODE from "../models/priority.tape";
use FLAG_URGENT, FLAG_BLOCKED from "../utils/task_flags.tape";
use User, make_user, admin_user from "../models/user.tape";

pub fn seed_demo_users() -> User {
    return admin_user("grace");
}

pub fn seed_reviewer() -> User {
    return make_user("ada", "reviewer");
}

pub fn seed_demo_tasks(s: TaskStore) -> Int {
    var a = store_add(s, "Write spec", "ada", 8, TODO_CODE, HIGH_CODE, 0);
    var b = store_add(s, "Fix parser", "grace", 13, DOING_CODE, URGENT_CODE, FLAG_URGENT);
    var c = store_add(s, "Add tests", "ada", 5, TODO_CODE, MEDIUM_CODE, 0);
    var d = store_add(s, "Review PR", "linus", 3, DOING_CODE, LOW_CODE, FLAG_BLOCKED);
    var e = store_add(s, "Ship release", "grace", 21, TODO_CODE, URGENT_CODE, FLAG_URGENT);
    return store_count(s);
}
