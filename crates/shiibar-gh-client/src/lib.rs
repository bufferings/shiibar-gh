//! Blocking client for the daemon socket: one request and one response per
//! connection, plus a long-lived `subscribe` stream.

use serde::de::DeserializeOwned;
use shiibar_gh_proto::paths::StateDir;
use shiibar_gh_proto::{ClientKind, ErrorCode, Lenient, Request, SubscribeEvent, codec};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// How long a one-shot request waits for its response.
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(30);
/// How long sending a request may block on a daemon that does not read.
const SEND_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug)]
pub enum ClientError {
    /// The daemon is not reachable.
    Connect(std::io::Error),
    /// The connection failed after it was established.
    Io(std::io::Error),
    /// The daemon sent something this client cannot read.
    Protocol(String),
    /// The daemon answered `{"ok":false,...}`.
    Remote {
        code: Lenient<ErrorCode>,
        message: String,
    },
}

impl ClientError {
    pub fn is_not_found(&self) -> bool {
        matches!(
            self,
            ClientError::Remote {
                code: Lenient::Known(ErrorCode::NotFound),
                ..
            }
        )
    }
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClientError::Connect(e) => write!(f, "cannot connect to shiibar-ghd: {e}"),
            ClientError::Io(e) => write!(f, "connection to shiibar-ghd failed: {e}"),
            ClientError::Protocol(message) => write!(f, "{message}"),
            ClientError::Remote { message, .. } => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for ClientError {}

/// The socket path from the environment, or `None` when no state directory
/// can be resolved.
pub fn socket_path_from_env() -> Option<PathBuf> {
    StateDir::from_env().map(|dir| dir.socket())
}

/// Send one request and decode the response as `T`.
pub fn request<T: DeserializeOwned>(socket: &Path, request: &Request) -> Result<T, ClientError> {
    let line = request_raw(socket, request)?;
    let value = parse_response(&line)?;
    serde_json::from_value(value)
        .map_err(|e| ClientError::Protocol(format!("invalid response from shiibar-ghd: {e}")))
}

/// Same round trip as [`request`], returning the success line untouched so
/// `--json` can forward what the daemon said.
pub fn request_json(socket: &Path, request: &Request) -> Result<String, ClientError> {
    let line = request_raw(socket, request)?;
    parse_response(&line)?;
    Ok(line.trim_end().to_string())
}

fn parse_response(line: &str) -> Result<serde_json::Value, ClientError> {
    let value: serde_json::Value = serde_json::from_str(line.trim_end())
        .map_err(|e| ClientError::Protocol(format!("invalid response from shiibar-ghd: {e}")))?;
    if value.get("ok").and_then(serde_json::Value::as_bool) == Some(true) {
        return Ok(value);
    }
    let code = value
        .get("code")
        .cloned()
        .map(serde_json::from_value)
        .transpose()
        .map_err(|e| ClientError::Protocol(format!("invalid response from shiibar-ghd: {e}")))?
        .unwrap_or_else(|| Lenient::Unknown(String::new()));
    let message = value
        .get("error")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("unknown error")
        .to_string();
    Err(ClientError::Remote { code, message })
}

fn request_raw(socket: &Path, request: &Request) -> Result<String, ClientError> {
    let mut stream = UnixStream::connect(socket).map_err(ClientError::Connect)?;
    stream
        .set_read_timeout(Some(RESPONSE_TIMEOUT))
        .map_err(ClientError::Io)?;
    stream
        .set_write_timeout(Some(SEND_TIMEOUT))
        .map_err(ClientError::Io)?;
    let line = codec::encode_line(request).map_err(|e| ClientError::Protocol(e.to_string()))?;
    stream.write_all(line.as_bytes()).map_err(ClientError::Io)?;
    let mut reader = BufReader::new(stream);
    let mut response = String::new();
    let read = reader.read_line(&mut response).map_err(ClientError::Io)?;
    if read == 0 {
        return Err(ClientError::Protocol(
            "shiibar-ghd closed the connection without a response".into(),
        ));
    }
    Ok(response)
}

/// A held `subscribe` connection. A long `snapshot` may arrive over several
/// reads; `BufRead::read_line` keeps what it has until the newline, and this
/// type keeps that partial line across a read timeout.
pub struct Subscription {
    reader: BufReader<UnixStream>,
    partial: String,
}

impl Subscription {
    pub fn open(socket: &Path, client: ClientKind) -> Result<Self, ClientError> {
        let mut stream = UnixStream::connect(socket).map_err(ClientError::Connect)?;
        stream
            .set_write_timeout(Some(SEND_TIMEOUT))
            .map_err(ClientError::Io)?;
        let line = codec::encode_line(&Request::Subscribe { client })
            .map_err(|e| ClientError::Protocol(e.to_string()))?;
        stream.write_all(line.as_bytes()).map_err(ClientError::Io)?;
        Ok(Self {
            reader: BufReader::new(stream),
            partial: String::new(),
        })
    }

    /// The next event. `Ok(None)` means the daemon closed the connection, and
    /// a timeout surfaces as `ClientError::Io` with the buffered bytes kept.
    pub fn next_event(
        &mut self,
        timeout: Option<Duration>,
    ) -> Result<Option<SubscribeEvent>, ClientError> {
        // macOS refuses this with EINVAL once the daemon has closed its side.
        // The read below then reports the close, which is the useful answer.
        let _ = self.reader.get_ref().set_read_timeout(timeout);
        match self.reader.read_line(&mut self.partial) {
            Ok(0) => Ok(None),
            // A connection cut in the middle of a write ends without a newline.
            Ok(_) if !self.partial.ends_with('\n') => Ok(None),
            Ok(_) => {
                let line = std::mem::take(&mut self.partial);
                codec::decode_line(&line)
                    .map(Some)
                    .map_err(|e| ClientError::Protocol(format!("invalid subscribe event: {e}")))
            }
            Err(e) => Err(ClientError::Io(e)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    /// Every blocking read in these tests fails after this instead of hanging.
    const TEST_WAIT: Duration = Duration::from_secs(10);

    #[test]
    fn a_line_split_over_several_reads_is_one_event() {
        let dir = tempfile_dir("split");
        let socket = dir.join("s.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(TEST_WAIT)).unwrap();
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap())
                .read_line(&mut request)
                .unwrap();
            let line = br#"{"event":"snapshot","accounts":[],"keychain":"ok","db_unreadable":true}
"#;
            let (head, tail) = line.split_at(10);
            stream.write_all(head).unwrap();
            stream.flush().unwrap();
            stream.write_all(tail).unwrap();
        });
        let mut subscription = Subscription::open(&socket, ClientKind::Cli).unwrap();
        let event = subscription
            .next_event(Some(Duration::from_secs(5)))
            .unwrap();
        assert_eq!(
            event,
            Some(SubscribeEvent::Snapshot {
                accounts: vec![],
                keychain: Lenient::Known(shiibar_gh_proto::KeychainState::Ok),
                db_unreadable: true
            })
        );
        server.join().unwrap();
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_connection_cut_inside_a_line_is_a_close() {
        let dir = tempfile_dir("cut");
        let socket = dir.join("s.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(TEST_WAIT)).unwrap();
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap())
                .read_line(&mut request)
                .unwrap();
            stream.write_all(br#"{"event":"snap"#).unwrap();
        });
        let mut subscription = Subscription::open(&socket, ClientKind::Cli).unwrap();
        let event = subscription.next_event(Some(Duration::from_secs(5)));
        assert!(matches!(event, Ok(None)), "{event:?}");
        server.join().unwrap();
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_close_that_came_before_the_read_is_a_close() {
        let dir = tempfile_dir("closed");
        let socket = dir.join("s.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let mut subscription = Subscription::open(&socket, ClientKind::Cli).unwrap();
        // Set while the peer is open: macOS refuses it after the close.
        let reader = subscription.reader.get_ref();
        reader.set_read_timeout(Some(TEST_WAIT)).unwrap();
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(TEST_WAIT)).unwrap();
        let mut request = String::new();
        BufReader::new(stream.try_clone().unwrap())
            .read_line(&mut request)
            .unwrap();
        drop(stream);
        // Reading to the end first makes sure the close has arrived.
        let mut peek = String::new();
        subscription.reader.read_line(&mut peek).unwrap();
        let event = subscription.next_event(Some(Duration::from_secs(5)));
        assert!(matches!(event, Ok(None)), "{event:?}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_not_found_response_is_recognized() {
        let error = parse_response(r#"{"ok":false,"code":"not_found","error":"no such PR"}"#)
            .expect_err("an error response");
        assert!(error.is_not_found());
        assert_eq!(error.to_string(), "no such PR");
    }

    #[test]
    fn an_unknown_error_code_is_still_an_error() {
        let error = parse_response(r#"{"ok":false,"code":"later","error":"nope"}"#)
            .expect_err("an error response");
        assert!(!error.is_not_found());
    }

    fn tempfile_dir(name: &str) -> PathBuf {
        // Kept short on purpose: Unix socket paths have a small length limit.
        let dir = std::env::temp_dir().join(format!("sgc-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
}
