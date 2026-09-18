//! Versioned, length-prefixed protocol shared by the local socket and SSH gateway.
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    io::{self, Read, Write},
    path::PathBuf,
};

pub const PROTOCOL_VERSION: u32 = 2;
pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_INPUT_BYTES: usize = 64 * 1024;
pub const DEFAULT_COLS: u16 = 120;
pub const DEFAULT_ROWS: u16 = 32;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionInfo {
    pub id: String,
    pub name: String,
    pub cwd: String,
    pub command: Vec<String>,
    pub cols: u16,
    pub rows: u16,
    pub state: SessionState,
    pub pid: Option<u32>,
    pub exit_code: Option<u32>,
    pub attached: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Running,
    Exited,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionList {
    pub host_id: String,
    pub sessions: Vec<SessionInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ClientMessage {
    Hello {
        version: u32,
    },
    List,
    Create {
        request_id: String,
        name: String,
        cwd: String,
        command: Vec<String>,
        #[serde(default)]
        env: BTreeMap<String, String>,
        cols: u16,
        rows: u16,
    },
    Attach {
        id: String,
        cols: u16,
        rows: u16,
        /// Revoke the existing controller before attaching. Older clients omit
        /// this field; callers require the `attach_takeover` host capability.
        #[serde(default)]
        takeover: bool,
    },
    Input {
        data: Vec<u8>,
    },
    Resize {
        cols: u16,
        rows: u16,
    },
    Detach,
    Kill {
        id: String,
    },
    /// Forget a completed session; running sessions must be terminated first.
    Remove {
        id: String,
    },
    /// A host with live sessions refuses shutdown.
    Shutdown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    Welcome {
        version: u32,
        host_id: String,
        capabilities: Vec<String>,
    },
    Sessions {
        host_id: String,
        sessions: Vec<SessionInfo>,
    },
    Created {
        session: SessionInfo,
    },
    Attached {
        /// Initial attachment or an atomic replacement snapshot after the
        /// shared terminal grid changes. Subsequent Output resumes at offset.
        session: SessionInfo,
        offset: u64,
        snapshot: Vec<u8>,
    },
    /// offset is the first byte position of this chunk, not its end.
    Output {
        offset: u64,
        data: Vec<u8>,
    },
    Exit {
        id: String,
        exit_code: u32,
    },
    Ok,
    Error {
        code: String,
        message: String,
    },
}

impl ServerMessage {
    pub fn error(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::Error {
            code: code.into(),
            message: message.into(),
        }
    }
}

pub fn valid_size(cols: u16, rows: u16) -> bool {
    (2..=500).contains(&cols) && (1..=200).contains(&rows)
}

pub fn default_socket_path() -> PathBuf {
    if let Some(path) = std::env::var_os("CHERRY_HOST_SOCKET") {
        return path.into();
    }
    // A short path also fits sockaddr_un on macOS. This directory must be 0700.
    PathBuf::from(format!("/tmp/cherry-host-{}/host.sock", unsafe {
        libc::geteuid()
    }))
}

pub fn write_frame<W: Write, T: Serialize>(writer: &mut W, value: &T) -> io::Result<()> {
    let bytes =
        serde_json::to_vec(value).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    if bytes.len() > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame exceeds limit",
        ));
    }
    writer.write_all(&(bytes.len() as u32).to_be_bytes())?;
    writer.write_all(&bytes)?;
    writer.flush()
}

pub fn read_frame<R: Read, T: DeserializeOwned>(reader: &mut R) -> io::Result<Option<T>> {
    let mut header = [0u8; 4];
    loop {
        match reader.read(&mut header[..1]) {
            Ok(0) => return Ok(None),
            Ok(_) => break,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    reader.read_exact(&mut header[1..])?;
    let len = u32::from_be_bytes(header) as usize;
    if len == 0 || len > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid frame length",
        ));
    }
    let mut bytes = vec![0; len];
    reader.read_exact(&mut bytes)?;
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn older_attach_requests_do_not_take_over() {
        let message: ClientMessage =
            serde_json::from_str(r#"{"op":"attach","id":"session","cols":80,"rows":24}"#).unwrap();
        assert!(matches!(
            message,
            ClientMessage::Attach {
                takeover: false,
                ..
            }
        ));
    }
    #[test]
    fn framing_handles_binary_payload_and_consecutive_messages() {
        let mut bytes = Vec::new();
        write_frame(
            &mut bytes,
            &ClientMessage::Input {
                data: vec![0, 255, 27],
            },
        )
        .unwrap();
        write_frame(&mut bytes, &ClientMessage::Detach).unwrap();
        let mut reader = bytes.as_slice();
        assert!(
            matches!(read_frame(&mut reader).unwrap(), Some(ClientMessage::Input {data}) if data == [0,255,27])
        );
        assert!(matches!(
            read_frame(&mut reader).unwrap(),
            Some(ClientMessage::Detach)
        ));
        assert!(read_frame::<_, ClientMessage>(&mut reader)
            .unwrap()
            .is_none());
    }
    #[test]
    fn rejects_oversize_and_truncated_frames() {
        let header = ((MAX_FRAME_BYTES + 1) as u32).to_be_bytes();
        assert!(read_frame::<_, ClientMessage>(&mut header.as_slice()).is_err());
        assert!(read_frame::<_, ClientMessage>(&mut [0u8, 0].as_slice()).is_err());
        assert!(read_frame::<_, ClientMessage>(&mut [0u8, 0, 0, 2, b'{'].as_slice()).is_err());
    }
}
