//! References: what a message, mail or note mentions that lives elsewhere,
//! a Jira ticket, a merge request or issue, a commit, a page, each written
//! one way however it was mentioned, so `ref:PLAT-12` finds them all.
//!
//! Links say what they are: `https://jira.example.com/browse/PLAT-12` is
//! `PLAT-12`, `https://gitlab.example.com/team/api/-/merge_requests/3` is
//! `team/api!3` (and `api!3`), a commit's link its hash (and the first 7
//! and 8 of it), and any link is also its host, path and query. What a link shows
//! is learned ([`Known`]): once `PLAT-12` has been linked, a bare `PLAT-9`
//! counts, and once `team/api` has, `api#4` and `team/api!5` do. Bare
//! keys and numbers nothing has shown aren't references, so `UTF-8` and
//! `#3` stay words.

use std::collections::BTreeSet;
use std::sync::LazyLock;

use regex::Regex;

/// What links have shown: Jira projects' keys (`PLAT`) and repositories'
/// paths (`team/api`), so bare mentions of them count.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Known {
    pub keys: BTreeSet<String>,
    pub repos: BTreeSet<String>,
}

static URL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"https?://[^\s<>"'`()\[\]{}|\\^]+"#).expect("a regex"));
static JIRA_PATH: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:^|/)browse/([A-Z][A-Z0-9_]+)-(\d+)$").expect("a regex"));
static JIRA_QUERY: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:^|&)selectedIssue=([A-Z][A-Z0-9_]+)-(\d+)(?:&|$)").expect("a regex")
});
static GITLAB: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^/([\w.-]+(?:/[\w.-]+)+)/-/(issues|work_items|merge_requests|commit)/(\w+)")
        .expect("a regex")
});
static GITHUB: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^/([\w.-]+/[\w.-]+)/(issues|pull|pulls|commit)/(\w+)").expect("a regex")
});
static BARE_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b([A-Z][A-Z0-9_]+)-(\d+)\b").expect("a regex"));
static BARE_REPO: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:^|[^\w/.-])((?:[\w.-]+/)*[\w.-]+)([#!])(\d+)\b").expect("a regex")
});
static HASH: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[0-9a-fA-F]{7,64}$").expect("a regex"));

/// A link found in text: the repository or Jira key it shows, and the
/// references it is.
struct Link {
    key: Option<String>,
    repo: Option<String>,
    refs: Vec<String>,
}

/// The links in `text`, each as far as the characters a link can't end
/// with, and where it is.
fn links(text: &str) -> impl Iterator<Item = (std::ops::Range<usize>, &str)> {
    URL.find_iter(text).map(|found| {
        let url = found
            .as_str()
            .trim_end_matches(['.', ',', ';', ':', '!', '?', '*', '_', '~']);
        (found.start()..found.start() + url.len(), url)
    })
}

/// What `url` is: its references, and what it shows to learn.
fn link(url: &str) -> Link {
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    let rest = rest.split_once('#').map_or(rest, |(before, _)| before);
    let (host, path) = rest
        .find('/')
        .map_or((rest, ""), |at| (&rest[..at], &rest[at..]));
    let (path, query) = path.split_once('?').unwrap_or((path, ""));
    let path = path.trim_end_matches('/');
    // A page can be named by its query (Confluence's `?pageId=`).
    let asked = if query.is_empty() {
        String::new()
    } else {
        format!("?{query}")
    };
    let mut found = Link {
        key: None,
        repo: None,
        refs: vec![format!("{}{path}{asked}", host.to_lowercase())],
    };
    if let Some(c) = JIRA_PATH
        .captures(path)
        .or_else(|| JIRA_QUERY.captures(query))
    {
        found.refs.push(format!("{}-{}", &c[1], &c[2]));
        found.key = Some(c[1].to_string());
    } else if let Some(c) = GITLAB.captures(path).or_else(|| GITHUB.captures(path)) {
        let repo = &c[1];
        let id = &c[3];
        match &c[2] {
            "commit" => found.refs.extend(commit(id)),
            kind => {
                let mark = if kind.starts_with("merge") || kind.starts_with("pull") {
                    '!'
                } else {
                    '#'
                };
                found.refs.extend(numbered(repo, mark, id));
            }
        }
        found.repo = Some(repo.to_string());
    }
    found
}

/// A commit's references: its hash and, from a longer one, the first 7 and
/// 8 of it, as short hashes are written. Nothing for what isn't a hash.
fn commit(hash: &str) -> Vec<String> {
    if !HASH.is_match(hash) {
        return Vec::new();
    }
    let hash = hash.to_lowercase();
    let mut refs: Vec<String> = [7, 8]
        .into_iter()
        .filter(|&n| hash.len() > n)
        .map(|n| hash[..n].to_string())
        .collect();
    refs.push(hash);
    refs
}

/// An issue's (`#`) or merge request's (`!`) references in `repo`: by its
/// path and by its name alone.
fn numbered(repo: &str, mark: char, number: &str) -> Vec<String> {
    let name = repo.rsplit('/').next().unwrap_or(repo);
    let mut refs = vec![format!("{repo}{mark}{number}")];
    if name != repo {
        refs.push(format!("{name}{mark}{number}"));
    }
    refs
}

/// Learns what the links in `text` show (Jira keys, repositories); true
/// when something was new.
pub fn learn(text: &str, known: &mut Known) -> bool {
    let mut learned = false;
    for (_, url) in links(text) {
        let found = link(url);
        if let Some(key) = found.key {
            learned |= known.keys.insert(key);
        }
        if let Some(repo) = found.repo {
            learned |= known.repos.insert(repo);
        }
    }
    learned
}

/// The references in `text`, sorted, each once: what its links are, and
/// the bare mentions `known` says are references.
#[must_use]
pub fn find(text: &str, known: &Known) -> Vec<String> {
    let mut refs: BTreeSet<String> = BTreeSet::new();
    // Bare mentions are looked for outside the links, which have their own.
    let mut bare = text.to_string();
    for (at, url) in links(text) {
        refs.extend(link(url).refs);
        bare.replace_range(at.clone(), &" ".repeat(at.len()));
    }
    if !known.keys.is_empty() {
        for c in BARE_KEY.captures_iter(&bare) {
            if known.keys.contains(&c[1]) {
                refs.insert(format!("{}-{}", &c[1], &c[2]));
            }
        }
    }
    if !known.repos.is_empty() {
        for c in BARE_REPO.captures_iter(&bare) {
            let (written, mark) = (&c[1], c[2].chars().next().unwrap_or('#'));
            let repos: Vec<&String> = if written.contains('/') {
                known.repos.get(written).into_iter().collect()
            } else {
                known
                    .repos
                    .iter()
                    .filter(|repo| repo.rsplit('/').next() == Some(written))
                    .collect()
            };
            for repo in repos {
                refs.extend(numbered(repo, mark, &c[3]));
            }
        }
    }
    refs.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn found(text: &str, known: &Known) -> Vec<String> {
        find(text, known)
    }

    #[test]
    fn a_jira_link_is_its_ticket_and_teaches_its_key() {
        let mut known = Known::default();
        let text = "see https://jira.example.com/browse/PLAT-1234, then PLAT-99";
        assert!(learn(text, &mut known));
        assert_eq!(
            found(text, &known),
            ["PLAT-1234", "PLAT-99", "jira.example.com/browse/PLAT-1234"]
        );
        assert!(!learn(text, &mut known), "nothing new the second time");
    }

    #[test]
    fn a_board_link_names_its_ticket_in_the_query() {
        let refs = found(
            "https://x.atlassian.net/jira/software/projects/OPS/boards/3?selectedIssue=OPS-7",
            &Known::default(),
        );
        assert!(refs.contains(&"OPS-7".to_string()), "{refs:?}");
    }

    #[test]
    fn bare_keys_nothing_linked_are_words() {
        let known = Known::default();
        assert!(found("UTF-8 and ISO-9001, PLAT-12", &known).is_empty());
        let mut known = Known::default();
        known.keys.insert("PLAT".into());
        assert_eq!(found("UTF-8 and PLAT-12.", &known), ["PLAT-12"]);
    }

    #[test]
    fn gitlab_links_are_issues_merge_requests_and_commits() {
        let text = "https://gitlab.example.com/team/sub/api/-/merge_requests/42 \
                    https://gitlab.example.com/team/sub/api/-/issues/7#note_1 \
                    https://gitlab.example.com/team/sub/api/-/commit/ABCDEF0123456789";
        let refs = found(text, &Known::default());
        for want in [
            "team/sub/api!42",
            "api!42",
            "team/sub/api#7",
            "api#7",
            "abcdef0",
            "abcdef01",
            "abcdef0123456789",
            "gitlab.example.com/team/sub/api/-/merge_requests/42",
            "gitlab.example.com/team/sub/api/-/issues/7",
        ] {
            assert!(refs.contains(&want.to_string()), "{want} in {refs:?}");
        }
    }

    #[test]
    fn github_links_are_issues_and_pull_requests() {
        let refs = found(
            "(https://github.com/acme/widget/pull/12) https://github.com/acme/widget/issues/3",
            &Known::default(),
        );
        for want in ["acme/widget!12", "widget!12", "acme/widget#3", "widget#3"] {
            assert!(refs.contains(&want.to_string()), "{want} in {refs:?}");
        }
    }

    #[test]
    fn bare_numbers_of_a_known_repository_count() {
        let mut known = Known::default();
        learn("https://gitlab.example.com/team/api/-/issues/1", &mut known);
        assert_eq!(known.repos, BTreeSet::from(["team/api".to_string()]));
        let refs = found("fixed in api!5 and team/api#9, not #3 or other#4", &known);
        assert_eq!(refs, ["api!5", "api#9", "team/api!5", "team/api#9"]);
    }

    #[test]
    fn any_link_is_its_host_and_path() {
        let refs = found(
            "the doc: <https://Wiki.example.com/pages/viewpage.action?pageId=12#top>.",
            &Known::default(),
        );
        assert_eq!(refs, ["wiki.example.com/pages/viewpage.action?pageId=12"]);
        let refs = found("https://grafana.example.com/d/abc/", &Known::default());
        assert_eq!(refs, ["grafana.example.com/d/abc"]);
    }

    #[test]
    fn text_without_links_has_none() {
        assert!(found("lunch at noon? #3 maybe", &Known::default()).is_empty());
    }
}
