use super::WinChild;
use crate::cmdbuilder::CommandBuilder;
use crate::win::procthreadattr::ProcThreadAttributeList;
use anyhow::{bail, ensure, Error};
use filedescriptor::{FileDescriptor, OwnedHandle};
use lazy_static::lazy_static;
use shared_library::shared_library;
use std::ffi::{OsStr, OsString};
use std::io::Error as IoError;
use std::os::windows::ffi::OsStringExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle};
use std::path::Path;
use std::sync::Mutex;
use std::{mem, ptr};
use winapi::shared::minwindef::DWORD;
use winapi::shared::winerror::{HRESULT, S_OK};
use winapi::um::handleapi::*;
use winapi::um::processthreadsapi::*;
use winapi::um::winbase::{
    CREATE_UNICODE_ENVIRONMENT, EXTENDED_STARTUPINFO_PRESENT, STARTF_USESTDHANDLES, STARTUPINFOEXW,
};
use winapi::um::wincon::COORD;
use winapi::um::winnt::HANDLE;
use winreg::enums::HKEY_LOCAL_MACHINE;
use winreg::RegKey;

pub type HPCON = HANDLE;

pub const PSUEDOCONSOLE_INHERIT_CURSOR: DWORD = 0x1;
pub const PSEUDOCONSOLE_RESIZE_QUIRK: DWORD = 0x2;
pub const PSEUDOCONSOLE_WIN32_INPUT_MODE: DWORD = 0x4;
#[allow(dead_code)]
pub const PSEUDOCONSOLE_PASSTHROUGH_MODE: DWORD = 0x8;
const WINDOWS_11_MIN_BUILD: u32 = 22_000;
const CONPTY_BACKEND_ENV: &str = "HERDR_CONPTY_BACKEND";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ConPtyBackend {
    System,
    Bundled,
}

fn conpty_backend_for(
    override_value: Option<&OsStr>,
    windows_build: Option<u32>,
) -> ConPtyBackend {
    if let Some(value) = override_value.and_then(OsStr::to_str).map(str::trim) {
        if value.eq_ignore_ascii_case("system") {
            return ConPtyBackend::System;
        }
        if value.eq_ignore_ascii_case("bundled") {
            return ConPtyBackend::Bundled;
        }
        if !value.is_empty() {
            log::warn!(
                "ignoring invalid {CONPTY_BACKEND_ENV} value `{value}`; expected `system` or `bundled`"
            );
        }
    }

    if windows_build.is_some_and(|build| build >= WINDOWS_11_MIN_BUILD) {
        ConPtyBackend::Bundled
    } else {
        // Modern app-local ConPTY preserves explicit black backgrounds emitted
        // by old PSReadLine. Windows 10's system ConPTY retains the compatible
        // default-background behavior users get outside Herdr.
        ConPtyBackend::System
    }
}

fn windows_build_number() -> Option<u32> {
    let current_version = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion")
        .ok()?;
    let build: String = current_version.get_value("CurrentBuildNumber").ok()?;
    build.parse().ok()
}

fn selected_conpty_backend() -> ConPtyBackend {
    let override_value = std::env::var_os(CONPTY_BACKEND_ENV);
    let windows_build = windows_build_number();
    let backend = conpty_backend_for(override_value.as_deref(), windows_build);
    log::info!("selected {backend:?} ConPTY backend for Windows build {windows_build:?}");
    backend
}

shared_library!(ConPtyFuncs,
    pub fn CreatePseudoConsole(
        size: COORD,
        hInput: HANDLE,
        hOutput: HANDLE,
        flags: DWORD,
        hpc: *mut HPCON
    ) -> HRESULT,
    pub fn ResizePseudoConsole(hpc: HPCON, size: COORD) -> HRESULT,
    pub fn ClosePseudoConsole(hpc: HPCON),
);

fn load_conpty() -> ConPtyFuncs {
    // If the kernel doesn't export these functions then their system is
    // too old and we cannot run.
    let kernel = ConPtyFuncs::open(Path::new("kernel32.dll")).expect(
        "this system does not support conpty.  Windows 10 October 2018 or newer is required",
    );
    if selected_conpty_backend() == ConPtyBackend::System {
        return kernel;
    }
    // Only load an app-local ConPTY that Herdr deliberately deployed beside
    // its executable. Never probe for a bare conpty.dll through the DLL search
    // path; that can select another application's incompatible package.
    let Some(exe_dir) = std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(Path::to_path_buf))
    else {
        return kernel;
    };
    let dll = exe_dir.join("conpty.dll");
    if !dll.is_file() {
        return kernel;
    }

    let host = exe_dir.join("OpenConsole.exe");
    assert!(
        host.is_file(),
        "bundled conpty.dll exists, but matching OpenConsole.exe is missing"
    );

    ConPtyFuncs::open(&dll).expect("failed to load bundled conpty.dll")
}

lazy_static! {
    static ref CONPTY: ConPtyFuncs = load_conpty();
}

pub struct PsuedoCon {
    con: HPCON,
}

unsafe impl Send for PsuedoCon {}
unsafe impl Sync for PsuedoCon {}

impl Drop for PsuedoCon {
    fn drop(&mut self) {
        unsafe { (CONPTY.ClosePseudoConsole)(self.con) };
    }
}

impl PsuedoCon {
    pub fn new(size: COORD, input: FileDescriptor, output: FileDescriptor) -> Result<Self, Error> {
        let mut con: HPCON = INVALID_HANDLE_VALUE;
        let result = unsafe {
            (CONPTY.CreatePseudoConsole)(
                size,
                input.as_raw_handle() as _,
                output.as_raw_handle() as _,
                PSUEDOCONSOLE_INHERIT_CURSOR
                    | PSEUDOCONSOLE_RESIZE_QUIRK
                    | PSEUDOCONSOLE_WIN32_INPUT_MODE,
                &mut con,
            )
        };
        ensure!(
            result == S_OK,
            "failed to create psuedo console: HRESULT {}",
            result
        );
        Ok(Self { con })
    }

    pub fn resize(&self, size: COORD) -> Result<(), Error> {
        let result = unsafe { (CONPTY.ResizePseudoConsole)(self.con, size) };
        ensure!(
            result == S_OK,
            "failed to resize console to {}x{}: HRESULT: {}",
            size.X,
            size.Y,
            result
        );
        Ok(())
    }

    pub fn spawn_command(&self, cmd: CommandBuilder) -> anyhow::Result<WinChild> {
        let mut si: STARTUPINFOEXW = unsafe { mem::zeroed() };
        si.StartupInfo.cb = mem::size_of::<STARTUPINFOEXW>() as u32;
        // Explicitly set the stdio handles as invalid handles otherwise
        // we can end up with a weird state where the spawned process can
        // inherit the explicitly redirected output handles from its parent.
        // For example, when daemonizing wezterm-mux-server, the stdio handles
        // are redirected to a log file and the spawned process would end up
        // writing its output there instead of to the pty we just created.
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        si.StartupInfo.hStdInput = INVALID_HANDLE_VALUE;
        si.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE;
        si.StartupInfo.hStdError = INVALID_HANDLE_VALUE;

        let mut attrs = ProcThreadAttributeList::with_capacity(1)?;
        attrs.set_pty(self.con)?;
        si.lpAttributeList = attrs.as_mut_ptr();

        let mut pi: PROCESS_INFORMATION = unsafe { mem::zeroed() };

        let (mut exe, mut cmdline) = cmd.cmdline()?;
        let cmd_os = OsString::from_wide(&cmdline);

        let cwd = cmd.current_directory();

        let res = unsafe {
            CreateProcessW(
                exe.as_mut_slice().as_mut_ptr(),
                cmdline.as_mut_slice().as_mut_ptr(),
                ptr::null_mut(),
                ptr::null_mut(),
                0,
                EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                cmd.environment_block().as_mut_slice().as_mut_ptr() as *mut _,
                cwd.as_ref()
                    .map(|c| c.as_slice().as_ptr())
                    .unwrap_or(ptr::null()),
                &mut si.StartupInfo,
                &mut pi,
            )
        };
        if res == 0 {
            let err = IoError::last_os_error();
            let msg = format!(
                "CreateProcessW `{:?}` in cwd `{:?}` failed: {}",
                cmd_os,
                cwd.as_ref().map(|c| OsString::from_wide(c)),
                err
            );
            log::error!("{}", msg);
            bail!("{}", msg);
        }

        // Make sure we close out the thread handle so we don't leak it;
        // we do this simply by making it owned
        let _main_thread = unsafe { OwnedHandle::from_raw_handle(pi.hThread as _) };
        let proc = unsafe { OwnedHandle::from_raw_handle(pi.hProcess as _) };

        Ok(WinChild {
            proc: Mutex::new(proc),
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conpty_backend_defaults_to_system_on_windows_10() {
        assert_eq!(
            conpty_backend_for(None, Some(19_045)),
            ConPtyBackend::System
        );
    }

    #[test]
    fn conpty_backend_defaults_to_bundled_on_windows_11() {
        assert_eq!(
            conpty_backend_for(None, Some(WINDOWS_11_MIN_BUILD)),
            ConPtyBackend::Bundled
        );
    }

    #[test]
    fn conpty_backend_fails_safe_when_windows_build_is_unknown() {
        assert_eq!(conpty_backend_for(None, None), ConPtyBackend::System);
    }

    #[test]
    fn conpty_backend_honors_explicit_overrides() {
        assert_eq!(
            conpty_backend_for(Some(OsStr::new("bundled")), Some(19_045)),
            ConPtyBackend::Bundled
        );
        assert_eq!(
            conpty_backend_for(Some(OsStr::new("SYSTEM")), Some(26_100)),
            ConPtyBackend::System
        );
    }
}