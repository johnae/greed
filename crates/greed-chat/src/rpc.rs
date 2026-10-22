//! JSON-RPC 2.0, one message a line, as `greed.rpc.start` with
//! `framing = "lines"` speaks it. Each request is answered on a task of its
//! own, so a slow one (a sign-in waiting for the browser) doesn't hold up
//! the rest; a service sends notifications whenever it likes through its
//! `Notifier`.

use std::future::Future;
use std::rc::Rc;

use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;

/// Why a request failed, as the client sees it: a JSON-RPC error with a
/// message meant for a person.
#[derive(Debug, Clone, PartialEq)]
pub struct Failure {
    pub code: i64,
    pub message: String,
}

impl Failure {
    /// A request that went wrong, saying why.
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            code: -32000,
            message: message.into(),
        }
    }

    /// A method nobody answers.
    pub fn unknown(method: &str) -> Self {
        Self {
            code: -32601,
            message: format!("there's no method {method}"),
        }
    }

    /// Parameters that aren't what the method takes.
    pub fn params(why: impl std::fmt::Display) -> Self {
        Self {
            code: -32602,
            message: format!("wrong parameters: {why}"),
        }
    }
}

/// A request's parameters as what the method takes.
pub fn parse<T: DeserializeOwned>(params: Value) -> Result<T, Failure> {
    serde_json::from_value(params).map_err(Failure::params)
}

/// Sends notifications to the client: `method` with `params`.
#[derive(Clone)]
pub struct Notifier(mpsc::UnboundedSender<String>);

impl Notifier {
    pub fn notify(&self, method: &str, params: &Value) {
        let message = json!({ "jsonrpc": "2.0", "method": method, "params": params });
        // Once the client is gone, nobody listens.
        let _ = self.0.send(message.to_string());
    }
}

/// What a service answers requests with.
pub trait Service: 'static {
    fn call(&self, method: &str, params: Value) -> impl Future<Output = Result<Value, Failure>>;
}

/// A notifier and the lines it sends, for `serve`.
pub fn notifier() -> (Notifier, mpsc::UnboundedReceiver<String>) {
    let (send, receive) = mpsc::unbounded_channel();
    (Notifier(send), receive)
}

/// Answers the requests on `input` with `service`, writing answers and the
/// notifications `notices` brings to `output`, until `input` ends. Runs on a
/// `LocalSet`, which spawns each request's task.
pub async fn serve<S: Service>(
    service: Rc<S>,
    input: impl AsyncBufRead + Unpin,
    mut output: impl AsyncWrite + Unpin,
    mut notices: mpsc::UnboundedReceiver<String>,
) -> std::io::Result<()> {
    let (answers, mut out) = mpsc::unbounded_channel::<String>();
    let mut lines = input.lines();
    loop {
        tokio::select! {
            line = lines.next_line() => {
                let Some(line) = line? else { break };
                if line.trim().is_empty() {
                    continue;
                }
                let service = Rc::clone(&service);
                let answers = answers.clone();
                tokio::task::spawn_local(async move {
                    if let Some(answer) = answer(&*service, &line).await {
                        let _ = answers.send(answer);
                    }
                });
            }
            Some(line) = out.recv() => write(&mut output, &line).await?,
            Some(line) = notices.recv() => write(&mut output, &line).await?,
        }
    }
    // What's still being answered gets its say before the end, with the
    // notifications it sends meanwhile.
    drop(answers);
    loop {
        tokio::select! {
            line = out.recv() => match line {
                Some(line) => write(&mut output, &line).await?,
                None => break,
            },
            Some(line) = notices.recv() => write(&mut output, &line).await?,
        }
    }
    while let Ok(line) = notices.try_recv() {
        write(&mut output, &line).await?;
    }
    Ok(())
}

async fn write(output: &mut (impl AsyncWrite + Unpin), line: &str) -> std::io::Result<()> {
    output.write_all(line.as_bytes()).await?;
    output.write_all(b"\n").await?;
    output.flush().await
}

/// The answer to one message, or none for a notification from the client.
async fn answer<S: Service>(service: &S, line: &str) -> Option<String> {
    let Ok(message) = serde_json::from_str::<Value>(line) else {
        let error = json!({ "code": -32700, "message": "that isn't JSON" });
        return Some(json!({ "jsonrpc": "2.0", "id": null, "error": error }).to_string());
    };
    let method = message.get("method").and_then(Value::as_str).unwrap_or("");
    let params = message.get("params").cloned().unwrap_or(Value::Null);
    let result = service.call(method, params).await;
    // A notification is run all the same, and isn't answered.
    let id = message.get("id").cloned()?;
    let reply = match result {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err(failure) => json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": failure.code, "message": failure.message },
        }),
    };
    Some(reply.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, BufReader};

    struct Echo(Notifier);

    impl Service for Echo {
        async fn call(&self, method: &str, params: Value) -> Result<Value, Failure> {
            match method {
                "echo" => Ok(params),
                "slow" => {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    Ok(json!("slow"))
                }
                "ping" => {
                    self.0.notify("pinged", &json!({ "with": params }));
                    Ok(Value::Null)
                }
                _ => Err(Failure::unknown(method)),
            }
        }
    }

    /// Runs `input` through an `Echo` and gives what it wrote, a line each.
    fn run(input: &str) -> Vec<Value> {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        let local = tokio::task::LocalSet::new();
        let out = local.block_on(&rt, async {
            let (notifier, notices) = notifier();
            let (mut theirs, ours) = tokio::io::duplex(64 * 1024);
            let service = Rc::new(Echo(notifier));
            serve(service, BufReader::new(input.as_bytes()), ours, notices)
                .await
                .unwrap();
            let mut out = String::new();
            theirs.read_to_string(&mut out).await.unwrap();
            out
        });
        out.lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    #[test]
    fn requests_are_answered_by_id_and_a_slow_one_holds_up_none() {
        let out = run(concat!(
            r#"{"jsonrpc":"2.0","id":1,"method":"slow"}"#,
            "\n",
            r#"{"jsonrpc":"2.0","id":2,"method":"echo","params":{"a":1}}"#,
            "\n",
        ));
        assert_eq!(out.len(), 2, "{out:?}");
        assert_eq!(out[0]["id"], 2, "the quick one first: {out:?}");
        assert_eq!(out[0]["result"], json!({ "a": 1 }));
        assert_eq!(out[1]["result"], "slow");
    }

    #[test]
    fn mistakes_say_what_went_wrong_and_notifications_go_out() {
        let out = run(concat!(
            "not json\n",
            r#"{"jsonrpc":"2.0","id":"x","method":"nope"}"#,
            "\n",
            r#"{"jsonrpc":"2.0","method":"ping","params":1}"#,
            "\n",
            r#"{"jsonrpc":"2.0","id":3,"method":"ping","params":2}"#,
            "\n",
        ));
        assert!(out.iter().any(|m| m["error"]["code"] == -32700), "{out:?}");
        let unknown = out.iter().find(|m| m["id"] == "x").unwrap();
        assert_eq!(unknown["error"]["code"], -32601);
        let pinged: Vec<&Value> = out.iter().filter(|m| m["method"] == "pinged").collect();
        assert_eq!(
            pinged.len(),
            2,
            "a notification from the client is still run: {out:?}"
        );
        assert!(out.iter().any(|m| m["id"] == 3 && m["result"].is_null()));
    }
}
