// Rendered reports: per-task lines plus aggregate verdict lines.
use TaskStore from "./task_store.tape";
use task_line from "./task_notifier.tape";
use dash_line from "../utils/string_utils.tape";
use health_verdict, busiest_owner from "./task_stats.tape";

pub fn report_line(s: TaskStore, i: Int) -> String {
    return task_line(s.titles[i], s.owners[i], s.status_codes[i]);
}

pub fn detailed_report(s: TaskStore) -> String {
    var out = dash_line(12);
    for (var i in 0..s.count) {
        out ++= " ";
        out ++= report_line(s, i);
    }
    out ++= " ";
    out ++= dash_line(12);
    return out;
}

pub fn verdict_line(s: TaskStore) -> String {
    return "verdict: " ++ health_verdict(s) ++ " | busiest: " ++ busiest_owner(s);
}
