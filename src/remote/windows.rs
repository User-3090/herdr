//! Windows-to-Windows remote thin-client launcher over OpenSSH command stdio.

use std::ffi::OsStr;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use interprocess::local_socket::{
    traits::{Listener as _, Stream as _},
    ListenerNonblockingMode,
};

const BRIDGE_ACCEPT_POLL: Duration = Duration::from_millis(50);
const CURRENT_PROTOCOL: u32 = crate::protocol::PROTOCOL_VERSION;
const REMOTE_HERDR_PATH: &str = r"C:\Herdr\herdr.exe";
const SSH_CONFIG_ENV_VAR: &str = "HERDR_SSH_CONFIG";

pub(crate) const REATTACH_COMMAND_ENV_VAR: &str = "HERDR_REATTACH_COMMAND";
pub(crate) const REMOTE_KEYBINDINGS_ENV_VAR: &str = "HERDR_REMOTE_KEYBINDINGS";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemoteKeybindings {
    Local,
    Server,
}

impl RemoteKeybindings {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "local" => Ok(Self::Local),
            "server" => Ok(Self::Server),
            _ => Err("--remote-keybindings must be 'local' or 'server'".to_string()),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Server => "server",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemoteLaunch {
    pub(crate) target: String,
    pub(crate) keybindings: RemoteKeybindings,
    pub(crate) live_handoff: bool,
}

pub(crate) fn extract_remote_args(
    args: &[String],
) -> Result<(Vec<String>, Option<RemoteLaunch>), String> {
    let mut cleaned = Vec::with_capacity(args.len());
    if let Some(program) = args.first() {
        cleaned.push(program.clone());
    }

    let mut remote_target = None;
    let mut keybindings = RemoteKeybindings::Local;
    let mut keybindings_seen = false;
    let mut live_handoff = false;
    let mut index = 1;
    while index < args.len() {
        let arg = &args[index];
        if arg == "--" {
            cleaned.extend_from_slice(&args[index..]);
            break;
        }
        if arg == "--handoff" {
            live_handoff = true;
            index += 1;
            continue;
        }
        if arg == "--remote" {
            if remote_target.is_some() {
                return Err("--remote can only be specified once".to_string());
            }
            let Some(value) = args.get(index + 1) else {
                return Err("missing value for --remote".to_string());
            };
            remote_target = Some(validate_remote_target(value)?.to_owned());
            index += 2;
            continue;
        }
        if let Some(value) = arg.strip_prefix("--remote=") {
            if remote_target.is_some() {
                return Err("--remote can only be specified once".to_string());
            }
            remote_target = Some(validate_remote_target(value)?.to_owned());
            index += 1;
            continue;
        }
        if arg == "--remote-keybindings" {
            if keybindings_seen {
                return Err("--remote-keybindings can only be specified once".to_string());
            }
            let Some(value) = args.get(index + 1) else {
                return Err("missing value for --remote-keybindings".to_string());
            };
            keybindings = RemoteKeybindings::parse(value)?;
            keybindings_seen = true;
            index += 2;
            continue;
        }
        if let Some(value) = arg.strip_prefix("--remote-keybindings=") {
            if keybindings_seen {
                return Err("--remote-keybindings can only be specified once".to_string());
            }
            keybindings = RemoteKeybindings::parse(value)?;
            keybindings_seen = true;
            index += 1;
            continue;
        }

        cleaned.push(arg.clone());
        index += 1;
    }

    let remote = remote_target.map(|target| RemoteLaunch {
        target,
        keybindings,
        live_handoff,
    });
    if remote.is_none() && keybindings_seen {
        return Err("--remote-keybindings requires --remote".to_string());
    }
    if remote.is_none() && live_handoff {
        cleaned.push("--handoff".to_string());
    }

    Ok((cleaned, remote))
}

fn validate_remote_target(target: &str) -> Result<&str, String> {
    if target.is_empty() {
        return Err("missing value for --remote".to_string());
    }
    if target.starts_with('-') {
        return Err("--remote target must not start with '-'".to_string());
    }
    Ok(target)
}

pub(crate) fn run_remote(remote: RemoteLaunch) -> io::Result<()> {
    debug_assert!(crate::platform::capabilities().remote_attach);
    if remote.live_handoff {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "live handoff is not supported for Windows remote attach",
        ));
    }

    let session_name = crate::session::active_name()
        .unwrap_or_else(|| crate::session::DEFAULT_SESSION_NAME.to_string());
    let local_socket = local_forward_socket_path(&remote.target, &session_name);
    let program = std::env::args()
        .next()
        .unwrap_or_else(|| "herdr.exe".to_string());
    let reattach_command =
        reattach_command(&program, &remote.target, &session_name, remote.keybindings);
    let _bridge = SshStdioBridge::start(remote.target, local_socket.clone(), session_name)?;

    run_client_process(&local_socket, &reattach_command, remote.keybindings)
}

pub(crate) fn run_remote_client_bridge() -> io::Result<()> {
    ensure_remote_server_running()?;

    let socket_path = crate::server::socket_paths::client_socket_path();
    let stream = crate::ipc::connect_local_stream(&socket_path).map_err(|err| {
        io::Error::new(
            err.kind(),
            format!(
                "failed to connect to remote Herdr client socket {}: {err}",
                socket_path.display()
            ),
        )
    })?;
    let (mut socket_to_stdout, mut stdin_to_socket) = stream.split();
    let mut stdout = io::stdout().lock();

    let _upload = thread::spawn(move || {
        let mut stdin = io::stdin();
        let _ = copy_flush(&mut stdin, &mut stdin_to_socket);
    });

    copy_flush(&mut socket_to_stdout, &mut stdout).map(|_| ())
}

fn ensure_remote_server_running() -> io::Result<()> {
    let socket_path = crate::server::socket_paths::client_socket_path();
    if crate::server::autodetect::is_server_listening() {
        let status = crate::api::read_runtime_status_at(
            &crate::api::socket_path(),
            Duration::from_millis(500),
        )?
        .ok_or_else(|| io::Error::other("remote server status API is unavailable"))?;
        if status.protocol == Some(CURRENT_PROTOCOL) {
            return Ok(());
        }
        return Err(io::Error::other(
            "remote herdr server must restart before this bridge can attach",
        ));
    }

    crate::server::autodetect::spawn_server_daemon()?;
    crate::server::autodetect::wait_for_server_socket(&socket_path, Duration::from_secs(15))
}

struct SshStdioBridge {
    local_socket: PathBuf,
    socket_identity: crate::ipc::SocketFileIdentity,
    should_stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl SshStdioBridge {
    fn start(target: String, local_socket: PathBuf, session_name: String) -> io::Result<Self> {
        crate::ipc::prepare_socket_path(&local_socket, |path| {
            format!("remote bridge is already listening at {}", path.display())
        })?;
        let listener = crate::ipc::bind_local_listener(&local_socket)?;
        let socket_identity = crate::ipc::socket_file_identity(&local_socket)?;
        listener.set_nonblocking(ListenerNonblockingMode::Accept)?;

        let should_stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&should_stop);
        let thread = thread::spawn(move || {
            while !thread_stop.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok(stream) => {
                        if let Err(err) = bridge_connection(stream, &target, &session_name) {
                            eprintln!("herdr: remote bridge failed: {err}");
                        }
                    }
                    Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(BRIDGE_ACCEPT_POLL);
                    }
                    Err(err) => {
                        eprintln!("herdr: remote bridge listener failed: {err}");
                        break;
                    }
                }
            }
        });

        Ok(Self {
            local_socket,
            socket_identity,
            should_stop,
            thread: Some(thread),
        })
    }
}

impl Drop for SshStdioBridge {
    fn drop(&mut self) {
        self.should_stop.store(true, Ordering::Release);
        let _ = crate::ipc::remove_socket_file_if_owned(&self.local_socket, &self.socket_identity);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn bridge_connection(
    stream: crate::ipc::LocalStream,
    target: &str,
    session_name: &str,
) -> io::Result<()> {
    let mut command = ssh_bridge_command(target, session_name);
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());

    let mut child = command
        .spawn()
        .map_err(|err| io::Error::new(err.kind(), format!("failed to start ssh bridge: {err}")))?;
    let mut child_stdin = child
        .stdin
        .take()
        .ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "ssh bridge stdin missing"))?;
    let mut child_stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "ssh bridge stdout missing"))?;
    let (mut stream_to_child, mut child_to_stream) = stream.split();

    let upload = thread::spawn(move || {
        let _ = copy_flush(&mut stream_to_child, &mut child_stdin);
    });
    let download = thread::spawn(move || {
        let _ = copy_flush(&mut child_stdout, &mut child_to_stream);
    });

    let status = child.wait()?;
    let _ = upload.join();
    let _ = download.join();

    if status.success() {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::ConnectionAborted,
            format!("ssh bridge exited with {status}"),
        ))
    }
}

fn ssh_bridge_command(target: &str, session_name: &str) -> Command {
    let config = std::env::var_os(SSH_CONFIG_ENV_VAR).filter(|value| !value.is_empty());
    ssh_bridge_command_with_config(target, session_name, config.as_deref())
}

fn ssh_bridge_command_with_config(
    target: &str,
    session_name: &str,
    config: Option<&OsStr>,
) -> Command {
    let mut command = Command::new("ssh.exe");
    command.arg("-T");
    if let Some(config) = config {
        command.arg("-F").arg(config);
    }
    command.arg(target).arg(remote_bridge_command(session_name));
    command
}

fn remote_bridge_command(session_name: &str) -> String {
    let mut command = format!("& {}", powershell_quote(REMOTE_HERDR_PATH));
    if session_name != crate::session::DEFAULT_SESSION_NAME {
        command.push_str(" --session ");
        command.push_str(&powershell_quote(session_name));
    }
    command.push_str(" remote-client-bridge");
    command
}

fn reattach_command(
    program: &str,
    target: &str,
    session_name: &str,
    keybindings: RemoteKeybindings,
) -> String {
    let program = if program.is_empty() {
        "herdr.exe"
    } else {
        program
    };
    let mut command = format!(
        "& {} --remote {}",
        powershell_quote(program),
        powershell_quote(target)
    );
    if keybindings != RemoteKeybindings::Local {
        command.push_str(" --remote-keybindings ");
        command.push_str(keybindings.as_str());
    }
    if session_name != crate::session::DEFAULT_SESSION_NAME {
        command.push_str(" --session ");
        command.push_str(&powershell_quote(session_name));
    }
    command
}

fn powershell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn run_client_process(
    local_socket: &Path,
    reattach_command: &str,
    keybindings: RemoteKeybindings,
) -> io::Result<()> {
    let exe = std::env::current_exe()?;
    let status = Command::new(exe)
        .arg("client")
        .env(
            crate::server::socket_paths::CLIENT_SOCKET_PATH_ENV_VAR,
            local_socket,
        )
        .env("HERDR_RENDER_ENCODING", "terminal-ansi")
        .env(REATTACH_COMMAND_ENV_VAR, reattach_command)
        .env(REMOTE_KEYBINDINGS_ENV_VAR, keybindings.as_str())
        .env_remove(crate::api::SOCKET_PATH_ENV_VAR)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()?;

    if status.success() {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::Interrupted,
            format!("remote client exited with {status}"),
        ))
    }
}

fn local_forward_socket_path(target: &str, session_name: &str) -> PathBuf {
    let target = sanitize_path_component(target);
    let session = sanitize_path_component(session_name);
    std::env::temp_dir().join(format!(
        "herdr-remote-{}-{target}-{session}.sock",
        std::process::id()
    ))
}

fn sanitize_path_component(input: &str) -> String {
    let sanitized: String = input
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
                ch
            } else {
                '-'
            }
        })
        .collect();
    sanitized.trim_matches('-').chars().take(32).collect()
}

fn copy_flush<R: io::Read, W: io::Write>(reader: &mut R, writer: &mut W) -> io::Result<u64> {
    let mut buffer = [0_u8; 16 * 1024];
    let mut total = 0;

    loop {
        let bytes_read = match reader.read(&mut buffer) {
            Ok(0) => return Ok(total),
            Ok(bytes_read) => bytes_read,
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        };
        writer.write_all(&buffer[..bytes_read])?;
        writer.flush()?;
        total += bytes_read as u64;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_remote_args_select_target_and_keybindings() {
        let args = vec![
            "herdr.exe".to_string(),
            "--remote".to_string(),
            "sandbox".to_string(),
            "--remote-keybindings=server".to_string(),
        ];

        let (cleaned, remote) = extract_remote_args(&args).unwrap();

        assert_eq!(cleaned, vec!["herdr.exe"]);
        assert_eq!(
            remote,
            Some(RemoteLaunch {
                target: "sandbox".to_string(),
                keybindings: RemoteKeybindings::Server,
                live_handoff: false,
            })
        );
    }

    #[test]
    fn windows_remote_bridge_uses_concrete_guest_executable() {
        assert_eq!(
            remote_bridge_command(crate::session::DEFAULT_SESSION_NAME),
            "& 'C:\\Herdr\\herdr.exe' remote-client-bridge"
        );
        assert_eq!(
            remote_bridge_command("agent's work"),
            "& 'C:\\Herdr\\herdr.exe' --session 'agent''s work' remote-client-bridge"
        );
    }

    #[test]
    fn windows_ssh_bridge_uses_openssh_without_cmd_wrapper() {
        let command = ssh_bridge_command_with_config(
            "sandbox",
            crate::session::DEFAULT_SESSION_NAME,
            Some(OsStr::new(r"C:\Runs\one\.ssh\config")),
        );
        let args = command
            .get_args()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect::<Vec<_>>();

        assert_eq!(command.get_program(), "ssh.exe");
        assert_eq!(
            args,
            vec![
                "-T".to_string(),
                "-F".to_string(),
                r"C:\Runs\one\.ssh\config".to_string(),
                "sandbox".to_string(),
                "& 'C:\\Herdr\\herdr.exe' remote-client-bridge".to_string(),
            ]
        );
    }

    #[test]
    fn windows_remote_socket_name_is_bounded_and_namespaced() {
        let path =
            local_forward_socket_path("ssh://sandbox host:2222/with/more/path", "agent's work");
        let name = path.file_name().unwrap().to_string_lossy();

        assert!(name.starts_with("herdr-remote-"));
        assert!(name.ends_with("-agent-s-work.sock"));
        assert!(!name.contains(':'));
        assert!(!name.contains('/'));
        assert!(name.len() < 100);
    }
}
