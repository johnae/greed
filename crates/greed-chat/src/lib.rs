//! What Greed's chat services share. Each service (Matrix, Mattermost) is
//! a program of its own, `greed-matrix` or `greed-mattermost`, that keeps
//! its accounts synced and answers Greed's chat client in one protocol
//! (`protocol`), over JSON-RPC one message a line on its input and output
//! (`rpc`), as `greed-mail serve` does for mail. The client never needs to
//! know which service it talks to, except for what a service says it can
//! do.

pub mod protocol;
pub mod rpc;
