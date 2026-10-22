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

/// `n` random bytes as hex, for ids and passphrases.
pub fn random(n: usize) -> String {
    let mut bytes = vec![0; n];
    getrandom::fill(&mut bytes).expect("the system has random numbers");
    bytes.iter().fold(String::new(), |mut hex, b| {
        let _ = write!(hex, "{b:02x}");
        hex
    })
}
