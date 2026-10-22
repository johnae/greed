//! `greed-matrix serve [--data DIR]`: Matrix for Greed's chat client.

use std::process::ExitCode;

fn main() -> ExitCode {
    greed_chat::program::main("matrix", greed_matrix::Matrix::new)
}
