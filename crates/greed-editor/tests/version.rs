use std::process::Command;

#[test]
fn version_names_the_release_and_whether_the_window_is_in() {
    for flag in ["--version", "-V"] {
        let output = Command::new(env!("CARGO_BIN_EXE_greed"))
            .arg(flag)
            .output()
            .unwrap();
        assert!(output.status.success());
        let printed = String::from_utf8(output.stdout).unwrap();
        let expected = if cfg!(feature = "gui") {
            format!("greed {}\n", env!("CARGO_PKG_VERSION"))
        } else {
            format!(
                "greed {} (terminal only: no --gui)\n",
                env!("CARGO_PKG_VERSION")
            )
        };
        assert_eq!(printed, expected);
    }
}
