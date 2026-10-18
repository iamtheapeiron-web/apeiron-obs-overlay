<p align="center">
  <img src="runtime/APEIRON_icon.png" width="128" alt="APEIRON">
</p>

# APEIRON OBS Overlay

**APEIRON OBS Overlay** is a lightweight Windows microphone-status overlay and global hotkey controller for OBS Studio.

> **Current release:** `v0.2.0-beta.1`  
> **Platform:** Windows 10/11 x64  
> **Status:** Beta, unsigned

## Features

- Global **Mute / Unmute** hotkey.
- **Hold Mode**: temporarily switches the microphone to the opposite state while a key is held, then restores the previous state.
- Configurable on-screen microphone indicator.
- Separate overlay behavior for normal microphone changes and Hold Mode.
- Custom position, size, shape, opacity and colors.
- OBS WebSocket connection with explicit audio-input selection.
- System-tray mode and optional Windows startup.
- Privilege-mismatch warning when OBS runs as Administrator.
- Single-instance protection.
- Per-user encrypted storage for a remembered OBS WebSocket password.

## Download

Use the [Releases](https://github.com/iamtheapeiron-web/apeiron-obs-overlay/releases) page for packaged Windows builds.

## Quick setup

1. In OBS open **Tools → WebSocket Server Settings**.
2. Enable the WebSocket server.
3. Run `APEIRON OBS Overlay.exe`.
4. Open the **OBS** tab, enter Host / Port / Password and click **Connect / refresh**.
5. Explicitly choose the audio input you want the app to control.
6. On **Controls**, assign the Mute / Unmute and Hold Mode keys.
7. Click **Save / Apply**.

## Overlay and capture

The overlay is designed for the streamer to see. OBS **Game Capture** / **Window Capture** normally do not include it, while **Display Capture** may. Make a short local recording before using it live.

## Hold Mode

Mute / Unmute changes the persistent base microphone state. Hold Mode temporarily applies the opposite state and restores the base state when released.

Hold display can:

- follow the normal overlay rules;
- remain visible for the entire hold;
- stay hidden during Hold Mode.

## Administrator mode

If OBS is running as Administrator, Windows may block global hotkeys from a non-elevated overlay. APEIRON OBS Overlay detects this mismatch and can restart itself with matching privileges.

## Privacy

The application connects to the OBS WebSocket server you configure. A remembered OBS password is encrypted for the current Windows user. **Copy diagnostics does not include the password.**

## Known issues

- Some games may experience input stutter or compatibility issues while APEIRON OBS Overlay is running.
- The current beta uses global keyboard and mouse hooks for hotkey detection, which may conflict with some games, input systems, overlays, or anti-cheat software.
- A compatibility update is planned to reduce unnecessary mouse-hook usage and improve game compatibility.

If you encounter this issue, please report the game name and what you experienced in [GitHub Issues](https://github.com/iamtheapeiron-web/apeiron-obs-overlay/issues/1).

## Building from source

See [BUILDING.md](BUILDING.md).

## Beta note

This is an **unsigned beta build**. Windows SmartScreen may show an unknown-publisher warning. Beta software may still contain bugs, so test your setup before a live stream.

## License

Released under the [MIT License](LICENSE).

## Links

- Website: https://apeiron.framer.media/
- Support: https://www.paypal.com/paypalme/StanislavMed
- Русская версия: [README_RU.md](README_RU.md)
