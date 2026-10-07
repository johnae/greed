use std::process::Command;

/// The variables `greed ARGS --env0` runs with, from `dir`.
fn environment(dir: &std::path::Path, args: &[&str]) -> Vec<String> {
    let output = Command::new(env!("CARGO_BIN_EXE_greed"))
        .args(args)
        .arg("--env0")
        .current_dir(dir)
        .env_clear()
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    output
        .stdout
        .split(|&b| b == 0)
        .map(|entry| String::from_utf8_lossy(entry).into_owned())
        .collect()
}

fn temp() -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("greed-profile-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.canonicalize().unwrap()
}

#[test]
fn folder_flags_become_variables_with_absolute_folders_for_all_greed_starts() {
    let dir = temp();
    let env = environment(&dir, &["--profile", "work"]);
    let profile = format!("GREED_PROFILE={}", dir.join("work").display());
    assert!(env.contains(&profile), "{env:?}");

    let env = environment(&dir, &["--config-dir", "/etc/greed", "--cache-dir", "c"]);
    assert!(
        env.contains(&"GREED_CONFIG_DIR=/etc/greed".to_owned()),
        "{env:?}"
    );
    let cache = format!("GREED_CACHE_DIR={}", dir.join("c").display());
    assert!(env.contains(&cache), "{env:?}");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_folder_flag_without_a_folder_says_so() {
    for args in [&["--profile"][..], &["--data-dir", "--env0"][..]] {
        let output = Command::new(env!("CARGO_BIN_EXE_greed"))
            .args(args)
            .env_clear()
            .output()
            .unwrap();
        assert!(!output.status.success());
        let said = String::from_utf8_lossy(&output.stderr);
        assert!(said.contains("needs a folder after it"), "{said}");
    }
}
