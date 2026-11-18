//! Compressing what goes between `greed ssh` and `greed bridge`, so it's
//! small over any transport. The client asks with [`ASK`] in the bridge's
//! environment; a bridge that compresses says so with [`MARKER`] as its
//! first line, after the attach request it reads as plain text, and from
//! then on both directions are one zstd stream each, a block flushed per
//! message. An older bridge leaves the variable alone and answers plainly,
//! and the client goes on without compressing.

use std::io::{self, BufRead, BufReader, Cursor, Read, Write};

/// The variable `greed ssh` sets for the bridge to compress.
pub const ASK: &str = "GREED_BRIDGE_ZSTD";

/// The line a compressing bridge sends first.
const MARKER: &str = "greed-zstd";

/// How hard zstd tries: frames are small and many, so fast beats tight.
const LEVEL: i32 = 3;

pub type Reader = Box<dyn BufRead + Send>;
pub type Writer = Box<dyn Write + Send>;

/// The bridge's side, the attach request read: compressed when the client
/// asked (`asked`), saying so first.
pub fn bridge(
    input: BufReader<impl Read + Send + 'static>,
    mut output: impl Write + Send + 'static,
    asked: bool,
) -> io::Result<(Reader, Writer)> {
    if !asked {
        return Ok((Box::new(input), Box::new(output)));
    }
    writeln!(output, "{MARKER}")?;
    output.flush()?;
    compressed(input, output)
}

/// The client's side, once it sent the attach request: compressed when
/// the bridge's first line says it compresses, else as they are, that line
/// read again.
pub fn client(
    mut input: impl BufRead + Send + 'static,
    output: impl Write + Send + 'static,
) -> io::Result<(Reader, Writer)> {
    let mut first = String::new();
    input.read_line(&mut first)?;
    if first.trim_end() == MARKER {
        return compressed(input, output);
    }
    let again = Cursor::new(first.into_bytes()).chain(input);
    Ok((Box::new(again), Box::new(output)))
}

fn compressed(
    input: impl BufRead + Send + 'static,
    output: impl Write + Send + 'static,
) -> io::Result<(Reader, Writer)> {
    let decoder = zstd::stream::read::Decoder::with_buffer(input)?;
    let encoder = zstd::stream::write::Encoder::new(output, LEVEL)?;
    Ok((Box::new(BufReader::new(decoder)), Box::new(encoder)))
}

#[cfg(test)]
mod tests {
    use std::os::unix::net::UnixStream;

    use super::*;

    /// A client and a bridge over a socket pair, as `greed ssh` and `greed
    /// bridge` meet: the client sends the attach request, which the bridge
    /// reads plain, then waits for the bridge's first line, which an older
    /// bridge (not `asked`) sends as its answer. The bridge's streams, then
    /// the client's.
    fn connect(asked: bool) -> ((Reader, Writer), (Reader, Writer)) {
        let (near, far) = UnixStream::pair().unwrap();
        writeln!(&near, "attach").unwrap();
        let mut input = BufReader::new(far.try_clone().unwrap());
        assert_eq!(
            line(&mut input),
            "attach\n",
            "the attach request goes plain"
        );
        let (input, mut output) = super::bridge(input, far, asked).unwrap();
        if !asked {
            writeln!(output, "answer").unwrap();
            output.flush().unwrap();
        }
        let client = super::client(BufReader::new(near.try_clone().unwrap()), near).unwrap();
        ((input, output), client)
    }

    fn line(reader: &mut impl BufRead) -> String {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        line
    }

    #[test]
    fn asked_both_ends_compress_each_message_as_its_own_block() {
        let ((mut bridge_in, mut bridge_out), (mut client_in, mut client_out)) = connect(true);
        for n in 0..3 {
            writeln!(bridge_out, "frame {n}").unwrap();
            bridge_out.flush().unwrap();
            assert_eq!(line(&mut client_in), format!("frame {n}\n"));
            writeln!(client_out, "key {n}").unwrap();
            client_out.flush().unwrap();
            assert_eq!(line(&mut bridge_in), format!("key {n}\n"));
        }
    }

    #[test]
    fn an_older_bridge_answers_plainly_and_nothing_is_compressed() {
        let ((mut bridge_in, mut bridge_out), (mut client_in, mut client_out)) = connect(false);
        assert_eq!(line(&mut client_in), "answer\n", "read again");
        writeln!(bridge_out, "frame").unwrap();
        bridge_out.flush().unwrap();
        assert_eq!(line(&mut client_in), "frame\n");
        writeln!(client_out, "key").unwrap();
        client_out.flush().unwrap();
        assert_eq!(line(&mut bridge_in), "key\n");
    }
}
