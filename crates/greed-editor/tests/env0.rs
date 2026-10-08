use std::process::Command;

#[test]
fn env0_prints_each_variable_exactly_ended_by_a_nul() {
    let output = Command::new(env!("CARGO_BIN_EXE_greed"))
        .arg("--env0")
        .env_clear()
        .env("PLAIN", "value")
        .env("LINES", "one\ntwo\n")
        .env("EQUALS", "a=b")
        .env("WIDE", "naïve ✓")
        .env("EMPTY", "")
        .output()
        .unwrap();
    assert!(output.status.success());
    let mut entries: Vec<&[u8]> = output.stdout.split(|&b| b == 0).collect();
    assert_eq!(entries.pop(), Some(&b""[..]), "every entry ends with a NUL");
    entries.sort_unstable();
    assert_eq!(
        entries,
        [
            &b"EMPTY="[..],
            b"EQUALS=a=b",
            b"LINES=one\ntwo\n",
            b"PLAIN=value",
            "WIDE=naïve ✓".as_bytes(),
        ]
    );
}
