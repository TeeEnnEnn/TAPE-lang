// TaskFlow demo entrypoint: wires every module together, drives the
// task lifecycle, and asserts the expected outcome at each step.
//
// Run the type checker with:
//   TAPE_lang check examples/taskflow/main.tape
use APP_NAME, APP_VERSION, MAX_TASKS, SEED_TASKS from "./config.tape";
use TaskStatus as Status from "./models/task_status.tape";
use TODO_CODE, DOING_CODE, DONE_CODE from "./models/task_status.tape";
use status_code, status_label from "./models/task_status.tape";
use Priority, priority_rank, priority_label from "./models/priority.tape";
use URGENT_CODE, HIGH_CODE, LOW_CODE from "./models/priority.tape";
use TaskError, task_error_name from "./models/task_error.tape";
use User, make_user, admin_user, user_display, user_is_admin from "./models/user.tape";
use Task, make_task, task_summary, task_is_done, task_effort, task_owner_tag from "./models/task.tape";
use clamp_int, min_int, max_int, percent_of, apply_to_estimate from "./utils/math_utils.tape";
use repeat_str, banner_str, dash_line from "./utils/string_utils.tape";
use FLAG_URGENT, FLAG_BLOCKED, has_task_flag, set_task_flag, clear_task_flag, flag_names from "./utils/task_flags.tape";
use valid_estimate, valid_slot, valid_task_id, clamp_estimate from "./utils/validators.tape";
use TaskStore, make_task_store, store_add, store_count, store_title_at, store_owner_at, store_estimate_at, store_status_at, store_priority_at, store_flags_at, store_total_estimate from "./services/task_store.tape";
use count_by_status, count_urgent, count_blocked, has_owner_task, first_open_slot from "./services/task_filters.tape";
use done_count, open_count, completion_percent, open_estimate_total, min_max_estimate, owner_load, load_table, busiest_owner, health_verdict from "./services/task_stats.tape";
use close_task, reopen_task, block_task, unblock_task, close_task_name from "./services/task_workflow.tape";
use header_block, task_line, done_message from "./services/task_notifier.tape";
use title_stream, estimate_stream, echo_estimate, drain_titles from "./services/task_scheduler.tape";
use report_line, detailed_report, verdict_line from "./services/task_report.tape";
use seed_demo_users, seed_reviewer, seed_demo_tasks from "./services/task_seed.tape";

// --- Config ---
if (APP_NAME != "TaskFlow") { panic "app name"; }
if (APP_VERSION != 3) { panic "app version"; }
if (MAX_TASKS != 8) { panic "max tasks"; }
if (SEED_TASKS != 5) { panic "seed tasks"; }

// --- Status model ---
var st = Status.Doing;
if (status_code(st) != 1) { panic "status code"; }
if (status_label(Status.Todo) != "todo") { panic "status label"; }
if (status_code(Status.Done) != DONE_CODE) { panic "done code"; }

// --- Priority model ---
var pr = Priority.Urgent;
if (priority_rank(pr) != 3) { panic "priority rank"; }
if (priority_label(Priority.Low) != "low") { panic "priority label"; }
if (URGENT_CODE != 3) { panic "urgent code"; }
if (HIGH_CODE != 2) { panic "high code"; }
if (LOW_CODE != 0) { panic "low code"; }

// --- Errors ---
if (task_error_name(TaskError.NotFound) != "not-found") { panic "err name"; }
if (task_error_name(TaskError.AlreadyDone) != "already-done") { panic "err done"; }

// --- Math / strings / flags / validators ---
if (clamp_int(99, 1, 40) != 40) { panic "clamp hi"; }
if (clamp_int(-5, 1, 40) != 1) { panic "clamp lo"; }
if (min_int(3, 21) != 3) { panic "min"; }
if (max_int(3, 21) != 21) { panic "max"; }
if (percent_of(2, 5) != 40) { panic "percent"; }
if (percent_of(1, 0) != 0) { panic "percent zero"; }
if (repeat_str("ab", 3) != "ababab") { panic "repeat"; }
if (banner_str("Hi") != "== Hi ==") { panic "banner"; }
if (dash_line(4) != "----") { panic "dashes"; }
var flag_bits = set_task_flag(0, FLAG_URGENT);
if (has_task_flag(flag_bits, FLAG_URGENT) != true) { panic "flag set"; }
if (has_task_flag(flag_bits, FLAG_BLOCKED) != false) { panic "flag unset"; }
if (flag_names(flag_bits) != "urgent") { panic "flag names"; }
var both = set_task_flag(flag_bits, FLAG_BLOCKED);
if (flag_names(both) != "urgent+blocked") { panic "flag names both"; }
if (clear_task_flag(both, FLAG_URGENT) != FLAG_BLOCKED) { panic "flag clear"; }
if (flag_names(0) != "none") { panic "flag none"; }
if (valid_estimate(8) != true) { panic "valid est"; }
if (valid_estimate(0) != false) { panic "invalid est"; }
if (valid_slot(7) != true) { panic "valid slot"; }
if (valid_slot(8) != false) { panic "invalid slot"; }
if (valid_task_id(1) != true) { panic "valid id"; }
if (valid_task_id(0) != false) { panic "invalid id"; }
if (clamp_estimate(99) != 40) { panic "clamp est"; }
var doubled = apply_to_estimate(21, fn (n: Int) -> Int { return n * 2; });
if (doubled != 42) { panic "closure apply"; }
var iife = fn (x: Int) -> Int { return x + 1; }(41);
if (iife != 42) { panic "iife"; }

// --- Users ---
var admin = admin_user("grace");
if (user_display(admin) != "grace<admin>") { panic "admin display"; }
if (user_is_admin(admin) != true) { panic "admin check"; }
var reviewer = seed_reviewer();
if (user_display(reviewer) != "ada<reviewer>") { panic "reviewer display"; }
if (user_is_admin(reviewer) != false) { panic "reviewer not admin"; }
var lead = seed_demo_users();
if (user_display(lead) != "grace<admin>") { panic "seed admin"; }
var plain_user: User = make_user("linus", "dev");
if (user_display(plain_user) != "linus<dev>") { panic "plain user"; }

// --- Single task view ---
var demo = make_task("Write spec", "ada", 8, TODO_CODE, HIGH_CODE, 0);
if (task_summary(demo) != "Write spec [todo]") { panic "task summary"; }
if (task_is_done(demo) != false) { panic "task open"; }
if (task_effort(demo) != "medium") { panic "task effort"; }
if (task_owner_tag(demo) != "ada/high") { panic "task owner tag"; }
var huge = make_task("Ship release", "grace", 21, TODO_CODE, URGENT_CODE, FLAG_URGENT);
if (task_effort(huge) != "huge") { panic "huge effort"; }
var tiny: Task = make_task("Ping", "ada", 1, DONE_CODE, LOW_CODE, 0);
if (task_is_done(tiny) != true) { panic "tiny done"; }
if (task_effort(tiny) != "small") { panic "tiny effort"; }

// --- Store + seed ---
var store = make_task_store();
if (store_count(store) != 0) { panic "empty store"; }
if (seed_demo_tasks(store) != 5) { panic "seed count"; }
if (store_count(store) != 5) { panic "store count"; }
if (store_total_estimate(store) != 50) { panic "total estimate"; }

var want_title_1: String | TaskError = "Write spec";
if (store_title_at(store, 1) != want_title_1) { panic "title 1"; }
var want_owner_2: String | TaskError = "grace";
if (store_owner_at(store, 2) != want_owner_2) { panic "owner 2"; }
var want_est_5: Int | TaskError = 21;
if (store_estimate_at(store, 5) != want_est_5) { panic "estimate 5"; }
var want_status_4: Int | TaskError = 1;
if (store_status_at(store, 4) != want_status_4) { panic "status 4"; }
var want_prio_3: Int | TaskError = 1;
if (store_priority_at(store, 3) != want_prio_3) { panic "priority 3"; }
var want_flags_2: Int | TaskError = 1;
if (store_flags_at(store, 2) != want_flags_2) { panic "flags 2"; }

// --- Filters before workflow ---
if (count_by_status(store, TODO_CODE) != 3) { panic "todo x3"; }
if (count_by_status(store, DOING_CODE) != 2) { panic "doing x2"; }
if (count_by_status(store, DONE_CODE) != 0) { panic "done x0"; }
if (count_urgent(store) != 2) { panic "urgent x2"; }
if (count_blocked(store) != 1) { panic "blocked x1"; }
if (has_owner_task(store, "ada") != true) { panic "has ada"; }
if (has_owner_task(store, "hopper") != false) { panic "no hopper"; }
var want_first_open: Int | TaskError = 1;
if (first_open_slot(store) != want_first_open) { panic "first open"; }

// --- Stats before workflow ---
if (done_count(store) != 0) { panic "done 0"; }
if (open_count(store) != 5) { panic "open 5"; }
if (completion_percent(store) != 0) { panic "pct 0"; }
if (open_estimate_total(store) != 50) { panic "open est 50"; }
if (health_verdict(store) != "behind") { panic "verdict behind"; }
if (busiest_owner(store) != "grace") { panic "busiest"; }
if (owner_load(store, "ada") != 13) { panic "ada load"; }
if (owner_load(store, "linus") != 3) { panic "linus load"; }
var loads = load_table(store);
if (loads["ada"] != 13) { panic "load ada"; }
if (loads["grace"] != 34) { panic "load grace"; }
if (loads["linus"] != 3) { panic "load linus"; }
var extremes = min_max_estimate(store);
if (extremes.0 != 3) { panic "min est"; }
if (extremes.1 != 21) { panic "max est"; }

// --- Workflow ---
var want_closed_2: Int | TaskError = 2;
if (close_task(store, 2) != want_closed_2) { panic "close 2"; }
var want_closed_4: Int | TaskError = 4;
if (close_task(store, 4) != want_closed_4) { panic "close 4"; }
var want_dup: Int | TaskError = TaskError.AlreadyDone;
if (close_task(store, 2) != want_dup) { panic "double close"; }
var close_missing = match (close_task(store, 99)) {
    TaskError.NotFound => give "gone";,
    TaskError.StoreFull => give "full";,
    TaskError.InvalidInput => give "bad";,
    TaskError.AlreadyDone => give "dup";,
    default => give "closed";
};
if (close_missing != "gone") { panic "close missing"; }
var want_blocked_1: Int | TaskError = 1;
if (block_task(store, 1) != want_blocked_1) { panic "block 1"; }
var want_flags_1: Int | TaskError = 2;
if (store_flags_at(store, 1) != want_flags_1) { panic "flags blocked"; }
if (unblock_task(store, 1) != want_blocked_1) { panic "unblock 1"; }
var want_flags_clear: Int | TaskError = 0;
if (store_flags_at(store, 1) != want_flags_clear) { panic "flags clear"; }
var want_reopened: Int | TaskError = 2;
if (reopen_task(store, 2) != want_reopened) { panic "reopen 2"; }
if (close_task(store, 2) != want_closed_2) { panic "reclose 2"; }
var reopen_open = match (reopen_task(store, 1)) {
    TaskError.NotFound => give "gone";,
    TaskError.StoreFull => give "full";,
    TaskError.InvalidInput => give "bad";,
    TaskError.AlreadyDone => give "dup";,
    default => give "reopened";
};
if (reopen_open != "bad") { panic "reopen open"; }
var want_close_name: String | TaskError = "Fix parser";
if (close_task_name(2) != want_close_name) { panic "close name"; }
var close_name_missing = match (close_task_name(7)) {
    TaskError.NotFound => give "gone";,
    TaskError.StoreFull => give "full";,
    TaskError.InvalidInput => give "bad";,
    TaskError.AlreadyDone => give "dup";,
    default => give "named";
};
if (close_name_missing != "gone") { panic "close name missing"; }

// --- Stats after workflow ---
if (done_count(store) != 2) { panic "done 2"; }
if (open_count(store) != 3) { panic "open 3"; }
if (completion_percent(store) != 40) { panic "pct 40"; }
if (open_estimate_total(store) != 34) { panic "open est 34"; }
if (health_verdict(store) != "steady") { panic "verdict steady"; }

// --- Notifications + reports ---
if (header_block() != "== TaskFlow ==") { panic "header"; }
if (task_line("Add tests", "ada", TODO_CODE) != "- 'Add tests' owner: ada status: todo") { panic "task line"; }
if (done_message("Fix parser") != "DONE 'Fix parser'") { panic "done msg"; }
var line0 = report_line(store, 0);
if (line0 != "- 'Write spec' owner: ada status: todo") { panic "report line"; }
var full_report = detailed_report(store);
if (full_report != "------------ - 'Write spec' owner: ada status: todo - 'Fix parser' owner: grace status: done - 'Add tests' owner: ada status: todo - 'Review PR' owner: linus status: done - 'Ship release' owner: grace status: todo ------------") { panic "full report"; }
if (verdict_line(store) != "verdict: steady | busiest: grace") { panic "verdict line"; }

// --- Scheduler coroutines ---
var stream = title_stream(store);
if ((resume stream) != "Write spec") { panic "stream 1"; }
if ((resume stream) != "Fix parser") { panic "stream 2"; }
if (drain_titles(store) != "drained") { panic "drain"; }
var est_handle = estimate_stream(store);
var est_sum = 0;
var est_seen = 0;
while (est_seen < store_count(store)) {
    est_sum += resume est_handle;
    est_seen += 1;
}
if (est_sum != 50) { panic "est sum"; }
var echo = echo_estimate(5);
if ((resume echo with 100) != 5) { panic "echo first"; }
if ((resume echo with 32) != 37) { panic "echo total"; }

// --- Local language exercises ---
var local_notes = {"spec": 1, "tests": 2};
if (local_notes["spec"] + local_notes["tests"] != 3) { panic "local table"; }
var local_pair = (3, 21);
if (local_pair.0 + local_pair.1 != 24) { panic "local tuple"; }
var range_sum = 0;
for (var r in 1..5) {
    range_sum += r;
}
if (range_sum != 10) { panic "range sum"; }

// --- Second store: empty + error paths ---
var probe = make_task_store();
var probe_open = match (first_open_slot(probe)) {
    TaskError.NotFound => give "empty";,
    TaskError.StoreFull => give "full";,
    TaskError.InvalidInput => give "bad";,
    TaskError.AlreadyDone => give "dup";,
    default => give "found";
};
if (probe_open != "empty") { panic "probe empty"; }
var probe_extremes = min_max_estimate(probe);
if (probe_extremes.0 != 0) { panic "probe min"; }
if (completion_percent(probe) != 0) { panic "probe pct"; }
var bad_add = match (store_add(probe, "Nope", "ada", 0, TODO_CODE, LOW_CODE, 0)) {
    TaskError.NotFound => give "gone";,
    TaskError.StoreFull => give "full";,
    TaskError.InvalidInput => give "bad";,
    TaskError.AlreadyDone => give "dup";,
    default => give "added";
};
if (bad_add != "bad") { panic "bad estimate"; }
var f1 = store_add(probe, "Extra A", "ada", 1, TODO_CODE, LOW_CODE, 0);
var f2 = store_add(probe, "Extra B", "ada", 2, TODO_CODE, LOW_CODE, 0);
var f3 = store_add(probe, "Extra C", "ada", 3, TODO_CODE, LOW_CODE, 0);
var f4 = store_add(probe, "Extra D", "ada", 4, TODO_CODE, LOW_CODE, 0);
var f5 = store_add(probe, "Extra E", "ada", 5, TODO_CODE, LOW_CODE, 0);
var f6 = store_add(probe, "Extra F", "ada", 6, TODO_CODE, LOW_CODE, 0);
var f7 = store_add(probe, "Extra G", "ada", 7, TODO_CODE, LOW_CODE, 0);
var f8 = store_add(probe, "Extra H", "ada", 8, TODO_CODE, LOW_CODE, 0);
if (store_count(probe) != 8) { panic "probe full"; }
var overflow = match (store_add(probe, "Extra I", "ada", 1, TODO_CODE, LOW_CODE, 0)) {
    TaskError.NotFound => give "gone";,
    TaskError.StoreFull => give "full";,
    TaskError.InvalidInput => give "bad";,
    TaskError.AlreadyDone => give "dup";,
    default => give "added";
};
if (overflow != "full") { panic "overflow"; }
var missing_title = match (store_title_at(probe, 9)) {
    TaskError.NotFound => give "gone";,
    TaskError.StoreFull => give "full";,
    TaskError.InvalidInput => give "bad";,
    TaskError.AlreadyDone => give "dup";,
    default => give "titled";
};
if (missing_title != "gone") { panic "missing title"; }

"taskflow ok";
