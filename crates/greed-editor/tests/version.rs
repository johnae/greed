use std::process::Command;

#[test]
fn version_names_the_release_its_build_and_whether_the_window_is_in() {
    for flag in ["--version", "-V"] {
        let output = Command::new(env!("CARGO_BIN_EXE_greed"))
            .arg(flag)
            .output()
            .unwrap();
        assert!(output.status.success());
        let printed = String::from_utf8(output.stdout).unwrap();
        let start = format!("greed {} (build ", env!("CARGO_PKG_VERSION"));
        let rest = printed
            .strip_prefix(&start)
            .unwrap_or_else(|| panic!("{printed}"));
        let (build, after) = rest.split_once(')').unwrap();
        assert!(
            build.len() == 12 && build.chars().all(|c| c.is_ascii_hexdigit()),
            "a short hash: {build}"
        );
        let window = if cfg!(feature = "gui") {
            "\n"
        } else {
            " (terminal only: no --gui)\n"
        };
        assert_eq!(after, window);
    }
}
