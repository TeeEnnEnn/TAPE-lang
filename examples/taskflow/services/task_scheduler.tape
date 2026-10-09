// Coroutine-based views over a `TaskStore`: lazy streams of titles and
// estimates, a request/response echo helper, and a driver that drains a
// title stream back into a plain value.
use TaskStore from "./task_store.tape";

pub co title_stream(s: TaskStore) -> (String, Nil, String) {
    for (var i in 0..s.count) {
        yield s.titles[i];
    }
    return "drained";
}

pub co estimate_stream(s: TaskStore) -> (Int, Nil, Int) {
    var i = 0;
    while (i < s.count) {
        yield s.estimates[i];
        i += 1;
    }
    return -1;
}

pub co echo_estimate(first: Int) -> (Int, Int, Int) {
    var extra = yield first;
    return first + extra;
}

pub fn drain_titles(s: TaskStore) -> String {
    var h = title_stream(s);
    var last = resume h;
    var i = 0;
    while (i < s.count) {
        last = resume h;
        i += 1;
    }
    return last;
}
