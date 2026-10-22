//! What Greed's chat services share. Each service (Matrix, Mattermost) is
//! a program of its own, `greed-matrix` or `greed-mattermost`, that keeps
//! its accounts synced and answers Greed's chat client in one protocol
//! (`protocol`), over JSON-RPC one message a line on its input and output
//! (`rpc`), as `greed-mail serve` does for mail. The client never needs to
//! know which service it talks to, except for what a service says it can
//! do.

pub mod loopback;
pub mod program;
pub mod protocol;
pub mod rpc;
#[doc(hidden)]
pub mod testing;

use std::fmt::Write;

/// What `error` says, with its causes after it where they add something:
/// "error sending request for url (…): client error (Connect): dns error:
/// failed to lookup address", where the error alone says only the first.
pub fn why(error: &dyn std::error::Error) -> String {
    let mut said = error.to_string();
    let mut cause = error.source();
    while let Some(next) = cause {
        let more = next.to_string();
        if !said.contains(&more) {
            said = format!("{said}: {more}");
        }
        cause = next.source();
    }
    said
}

/// `n` random bytes as hex, for ids and passphrases.
pub fn random(n: usize) -> String {
    let mut bytes = vec![0; n];
    getrandom::fill(&mut bytes).expect("the system has random numbers");
    bytes.iter().fold(String::new(), |mut hex, b| {
        let _ = write!(hex, "{b:02x}");
        hex
    })
}

/// `name` made safe to be a file's name, like a fetched file's.
pub fn safe_file_name(name: &str) -> String {
    let safe: String = name
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || ".-_".contains(c) {
                c
            } else {
                '_'
            }
        })
        .collect();
    safe.trim_start_matches('.').chars().take(120).collect()
}

#[cfg(test)]
mod tests {
    use super::why;

    #[test]
    fn says_an_error_with_its_causes_once_each() {
        let io = std::io::Error::other("dns error: failed to lookup address");
        let wrapped = std::io::Error::other(Wrapped(io));
        assert_eq!(
            why(&Wrapped(wrapped)),
            "error sending request: dns error: failed to lookup address"
        );
    }

    /// An error that says only that it failed, with its cause as source.
    #[derive(Debug)]
    struct Wrapped<E>(E);

    impl<E: std::error::Error + 'static> std::fmt::Display for Wrapped<E> {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("error sending request")
        }
    }

    impl<E: std::error::Error + 'static> std::error::Error for Wrapped<E> {
        fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
            Some(&self.0)
        }
    }
}
