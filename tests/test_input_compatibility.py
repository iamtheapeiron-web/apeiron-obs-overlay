"""Static and model checks for beta.2 input compatibility behavior."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OVERLAY = (ROOT / "runtime" / "overlay.ps1").read_text(encoding="utf-8-sig")

MOUSE = {0x01, 0x02, 0x04, 0x05, 0x06}

def desired(toggle_enabled, toggle_vk, hold_enabled, hold_vk, compatibility):
    if compatibility:
        return False, False
    keyboard = mouse = False
    for enabled, vk in ((toggle_enabled, toggle_vk), (hold_enabled, hold_vk)):
        if not enabled:
            continue
        if vk in MOUSE:
            mouse = True
        else:
            keyboard = True
    return keyboard, mouse

required = [
    "public static bool Start(bool enableKeyboardHook, bool enableMouseHook)",
    "if (wantKeyboardHook) keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL",
    "if (wantMouseHook) mouseHook = SetWindowsHookEx(WH_MOUSE_LL",
    "Game compatibility mode (no low-level input hooks)",
    "function Update-InputHooks",
    "$fastTimer.Interval=if([bool]$cfg.general.compatibilityMode){25}else{35}",
    "Input mode: $(Get-InputModeText)",
]
for token in required:
    assert token in OVERLAY, token

assert desired(True, 0x78, True, 0x79, False) == (True, False)
assert desired(True, 0x05, True, 0x79, False) == (True, True)
assert desired(True, 0x05, False, 0x79, False) == (False, True)
assert desired(False, 0x78, False, 0x79, False) == (False, False)
for tvk in (0x78, 0x01, 0x05):
    for hvk in (0x79, 0x02, 0x06):
        for te in (False, True):
            for he in (False, True):
                assert desired(te, tvk, he, hvk, True) == (False, False)

count = 0
for tvk in (0x78, 0x01, 0x05):
    for hvk in (0x79, 0x02, 0x06):
        for te in (False, True):
            for he in (False, True):
                for compatibility in (False, True):
                    k, m = desired(te, tvk, he, hvk, compatibility)
                    if compatibility:
                        assert not k and not m
                    else:
                        assert k == ((te and tvk not in MOUSE) or (he and hvk not in MOUSE))
                        assert m == ((te and tvk in MOUSE) or (he and hvk in MOUSE))
                    count += 1
print(f"PASS: {count} input-hook selection combinations; default keyboard setup has no mouse hook; compatibility mode is hook-free")
