//! Programs Greed starts can be stopped with ctrl-c even when Greed itself
//! was started ignoring it, as a shell's background job is. In a file of its
//! own, since it changes what this whole test process does with SIGINT.

#![allow(unsafe_code)]

use std::time::Duration;

use greed_core::Editor;
use greed_core::luau::Host;
use greed_text::ClientId;
use nix::sys::signal::{SigHandler, Signal, signal};

#[test]
fn a_program_started_while_greed_ignores_sigint_can_be_interrupted() {
    // SAFETY: before any other thread of this test process could be
    // handling SIGINT; it only makes the signal ignored, as `cmd &` does.
    unsafe { signal(Signal::SIGINT, SigHandler::SigIgn) }.unwrap();
    // As Greed does first thing.
    greed_core::child::pass_on_signals();
    let host = Host::new(Editor::new(ClientId(1))).unwrap();
    host.eval(
        "local greed = require('@greed')
         greed.spawn(function()
             local child = assert(greed.process.spawn({ 'sh', '-c', 'kill -INT $$; echo survived' }))
             local out = ''
             while true do
                 local piece = child:read()
                 if piece == nil then break end
                 out ..= piece
             end
             local code, how = child:wait()
             ended = `{out}|{code}|{how}`
         end)",
    )
    .unwrap();
    let jobs = host.finished_jobs();
    while host.eval("return ended == nil").unwrap() == "true" {
        let done = jobs.recv_timeout(Duration::from_secs(10)).unwrap();
        host.finish_job(done).unwrap();
    }
    assert_eq!(host.eval("return ended").unwrap(), "|nil|INT");
}
