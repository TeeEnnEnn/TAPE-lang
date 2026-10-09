// String building blocks for notifications and reports.
pub fn repeat_str(s: String, n: Int) -> String {
    var out = "";
    var i = 0;
    while (i < n) {
        out ++= s;
        i += 1;
    }
    return out;
}

pub fn banner_str(title: String) -> String {
    return "== " ++ title ++ " ==";
}

pub fn quoted_str(s: String) -> String {
    return "'" ++ s ++ "'";
}

pub fn dash_line(n: Int) -> String {
    return repeat_str("-", n);
}

pub fn tag_pair(key: String, value: String) -> String {
    return key ++ ": " ++ value;
}
