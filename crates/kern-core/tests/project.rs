use std::path::Path;

use kern_core::project::{root_of, session_name};

#[test]
fn a_projects_root_is_the_nearest_folder_with_a_marker() {
    let dir = std::env::temp_dir().join(format!("kern-root-{}", std::process::id()));
    std::fs::create_dir_all(dir.join(".git")).unwrap();
    std::fs::create_dir_all(dir.join("src/deep")).unwrap();
    std::fs::write(dir.join("src/deep/a.rs"), "").unwrap();
    std::fs::create_dir_all(dir.join("other/.jj")).unwrap();
    assert_eq!(root_of(&dir.join("src/deep/a.rs")), dir);
    assert_eq!(root_of(&dir.join("src/deep")), dir);
    assert_eq!(root_of(&dir.join("other")), dir.join("other"));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn session_names_come_from_the_folder_and_dont_clash() {
    let taken = vec!["kern".to_owned(), "kern-2".to_owned()];
    assert_eq!(session_name(Path::new("/src/Kern"), &[]), "kern");
    assert_eq!(session_name(Path::new("/src/kern"), &taken), "kern-3");
    assert_eq!(session_name(Path::new("/src/my notes"), &[]), "my-notes");
    assert_eq!(session_name(Path::new("/"), &[]), "kern");
}

#[test]
fn long_folder_names_make_short_session_names() {
    let long = "a-project-folder-with-a-very-long-name-indeed-really";
    let name = session_name(&Path::new("/src").join(long), &[]);
    assert!(name.len() <= 32, "{name}");
    assert!(long.starts_with(&name));
    let taken = vec![name.clone()];
    let second = session_name(&Path::new("/src").join(long), &taken);
    assert!(second.len() <= 32 && second != name, "{second}");
}
