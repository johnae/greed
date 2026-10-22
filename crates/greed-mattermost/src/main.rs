//! `greed-mattermost serve [--data DIR]`: Mattermost for Greed's chat client.

use std::process::ExitCode;

fn main() -> ExitCode {
    greed_chat::program::main("mattermost", greed_mattermost::Mattermost::new)
}
