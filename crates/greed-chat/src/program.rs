//! What every service's program does: `greed-SERVICE serve [--data DIR]`
//! answers Greed's chat client on its input and output, keeping what it
//! stores in DIR (Greed's data folder's SERVICE by default).

use std::future::Future;
use std::path::PathBuf;
use std::process::ExitCode;
use std::rc::Rc;

use tokio::io::BufReader;

use crate::rpc::{self, Notifier, Service};

/// Runs the program for `service`, made by `make` with its data folder.
pub fn main<S: Service>(service: &str, make: impl FnOnce(PathBuf, Notifier) -> Rc<S>) -> ExitCode {
    let program = format!("greed-{service}");
    // A panic ends it at once, said as its other troubles are: unwinding
    // would wait for the thread reading its input, and it would hang on,
    // answering nothing.
    let panicked = std::panic::take_hook();
    let named = program.clone();
    std::panic::set_hook(Box::new(move |info| {
        panicked(info);
        let payload = info.payload();
        let what = payload
            .downcast_ref::<&str>()
            .copied()
            .or_else(|| payload.downcast_ref::<String>().map(String::as_str))
            .unwrap_or("it panicked");
        eprintln!("{named}: {what}");
        std::process::exit(101);
    }));
    let usage = format!("usage: {program} serve [--data DIR]");
    let fail = |message: &str| {
        eprintln!("{program}: {message}");
        ExitCode::FAILURE
    };
    let mut args = std::env::args().skip(1);
    let mut data: Option<PathBuf> = None;
    let mut serve = false;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "serve" => serve = true,
            "--data" => match args.next() {
                Some(dir) => data = Some(dir.into()),
                None => return fail(&usage),
            },
            "-h" | "--help" | "help" => {
                println!("{usage}");
                return ExitCode::SUCCESS;
            }
            _ => return fail(&usage),
        }
    }
    if !serve {
        return fail(&usage);
    }
    let data =
        data.or_else(|| greed_dirs::dir(greed_dirs::Kind::Data).map(|dir| dir.join(service)));
    let Some(data) = data else {
        return fail("can't tell where Greed's data folder is: set HOME or GREED_DATA_DIR");
    };
    if let Err(e) = std::fs::create_dir_all(&data) {
        return fail(&format!("can't make {}: {e}", data.display()));
    }
    let served = run(async move {
        let (notifier, notices) = rpc::notifier();
        let input = BufReader::new(tokio::io::stdin());
        rpc::serve(make(data, notifier), input, tokio::io::stdout(), notices).await
    });
    match served {
        Some(Ok(())) => ExitCode::SUCCESS,
        Some(Err(e)) => fail(&e.to_string()),
        None => fail("couldn't start"),
    }
}

/// Runs `work` to the end on a runtime of one thread with a `LocalSet`, as
/// services run, or None when there's no runtime to be had. Whatever its
/// tasks leave behind is dropped while the runtime is still there, as
/// database pools and the like need.
pub fn run<T>(work: impl Future<Output = T>) -> Option<T> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .ok()?;
    let local = tokio::task::LocalSet::new();
    let done = local.block_on(&runtime, work);
    {
        let _inside = runtime.enter();
        drop(local);
    }
    // Libraries leave work on the blocking threads (a sync's long poll);
    // it's not waited for.
    runtime.shutdown_timeout(std::time::Duration::from_secs(1));
    Some(done)
}
