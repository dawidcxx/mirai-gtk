pub fn fmtBool(b: bool) [:0]const u8 {
    if (b) {
        return "yes";
    } else {
        return "no";
    }
}
