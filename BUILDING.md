# Building APEIRON OBS Overlay

## Runtime

- Windows PowerShell 5.1 / .NET Framework (built into supported Windows versions).
- No Python or external modules are required by end users.

## Launcher

The launcher is written in Go and targets Windows x64 with the GUI subsystem.
It embeds the PowerShell runtime and APEIRON icon assets.

## Build requirements

- Go 1.22 or later.
- Python 3.
- MinGW `windres` (`x86_64-w64-mingw32-windres`) for Windows resources.

From the repository root:

```text
python build.py
```

Optional build arguments are available for Go, windres, a resource preprocessor and output path.

`build.py` refreshes `launcher/payload/` from `runtime/` before compiling. The checked-in payload is kept so the launcher tests can also run directly from a fresh clone.

## Tests

Launcher tests:

```text
cd launcher
go test ./...
go vet ./...
```

Other tests under `tests/` cover production runtime logic, OBS WebSocket protocol behavior, the embedded native C# block and PE resource verification. Some of these require Windows / PowerShell 7 or a local Python WebSocket dependency.

Windows-specific behavior such as UAC, global hotkeys, taskbar/tray behavior and full-screen games should also be smoke-tested on Windows with OBS.
