//! `greed-matrix serve [--data DIR]`: answers Greed's chat client on its
//! input and output, keeping each account's store in DIR (Greed's data
//! folder's `matrix` by default).

use std::path::PathBuf;
use std::process::ExitCode;

use greed_chat::rpc;
use greed_matrix::Matrix;
use tokio::io::BufReader;

const USAGE: &str = "usage: greed-matrix serve [--data DIR]";

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let mut data: Option<PathBuf> = None;
    let mut serve = false;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "serve" => serve = true,
            "--data" => match args.next() {
                Some(dir) => data = Some(dir.into()),
                None => return fail(USAGE),
            },
            "-h" | "--help" | "help" => {
                println!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            _ => return fail(USAGE),
        }
    }
    if !serve {
        return fail(USAGE);
    }
    let data =
        data.or_else(|| greed_dirs::dir(greed_dirs::Kind::Data).map(|dir| dir.join("matrix")));
    let Some(data) = data else {
        return fail("can't tell where Greed's data folder is: set HOME or GREED_DATA_DIR");
    };
    if let Err(e) = std::fs::create_dir_all(&data) {
        return fail(&format!("can't make {}: {e}", data.display()));
    }
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(e) => return fail(&format!("couldn't start: {e}")),
    };
    let (notifier, notices) = rpc::notifier();
    let matrix = Matrix::new(data, notifier);
    let local = tokio::task::LocalSet::new();
    let served = local.block_on(
        &runtime,
        rpc::serve(
            matrix,
            BufReader::new(tokio::io::stdin()),
            tokio::io::stdout(),
            notices,
        ),
    );
    match served {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => fail(&e.to_string()),
    }
}

fn fail(message: &str) -> ExitCode {
    eprintln!("greed-matrix: {message}");
    ExitCode::FAILURE
}
