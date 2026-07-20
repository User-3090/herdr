# portable-pty local patches

This file tracks intentional local changes applied on top of the vendored
`portable-pty` source. Remove a patch only when the upstream crate contains an
equivalent fix or exposes an option that lets Herdr keep the same behavior.

## 0001 controlled app-local ConPTY

status: active

patch: `vendor/patches/portable-pty/0001-controlled-app-local-conpty.patch`

herdr issue: https://github.com/ogulcancelik/herdr/issues/761

upstream discussion: none found

upstream pr: none

vendored base: `portable-pty 0.9.0`

local files:

- `vendor/portable-pty/src/win/psuedocon.rs`

reason: `portable-pty` intentionally probes a bare `conpty.dll` after verifying
that `kernel32.dll` exports the ConPTY API. Herdr must not load another
application's DLL from the search path. It may use Microsoft's pinned app-local
package when `conpty.dll` and its matching `OpenConsole.exe` are deliberately
deployed beside `herdr.exe`; otherwise it retains the system implementation.

remove when: upstream `portable-pty` accepts an explicit absolute app-local
ConPTY path with a system fallback, or Herdr replaces the Windows PTY backend.

verification:

```sh
python3 -m unittest scripts.test_vendor_portable_pty
```

On Windows, verify that a PATH-only `conpty.dll` is ignored, a sibling Microsoft
pair starts the sibling `OpenConsole.exe`, and removing the pair restores system
ConPTY.

## 0002 expose Windows raw command tails

status: active

patch: `vendor/patches/portable-pty/0002-windows-raw-command-tail.patch`

herdr issue: https://github.com/ogulcancelik/herdr/issues/1041

upstream discussion: none

upstream pr: none

vendored base: `portable-pty 0.9.0`

local files:

- `vendor/portable-pty/src/cmdbuilder.rs`

reason: Herdr needs to launch `cmd.exe /d /c` with the user-authored command
tail parsed as shell text. `portable-pty` represents commands as argv and
ArgvQuote escapes embedded quotes, which changes how `cmd.exe` parses the raw
command string.

remove when: upstream `portable-pty` exposes Windows raw command-line tail
support or Herdr replaces this launch path.

verification:

```sh
python3 -m unittest scripts.test_vendor_portable_pty
```

On Windows, also run `cargo test raw_arg_appends_unescaped_windows_command_tail`.
