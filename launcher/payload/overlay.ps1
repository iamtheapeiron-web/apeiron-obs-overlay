# APEIRON OBS Overlay v0.2 beta1, build 4
# Windows PowerShell 5.1 / Windows 10-11
# No Python or external modules required.

param([switch]$DebugMode, [int]$WaitForPid=0, [switch]$StartupMode)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if ($WaitForPid -gt 0) {
    try {
        $previous=[Diagnostics.Process]::GetProcessById($WaitForPid)
        if (-not $previous.WaitForExit(20000)) { throw "The previous instance has not exited." }
    } catch [ArgumentException] {} # The previous process already exited.
}

# A second guard also protects direct runtime-script launches.
$instanceName = "Local\APEIRON.OBSOverlay.Script." + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:instanceMutex = New-Object Threading.Mutex($false, $instanceName)
$script:ownsInstance = $false
try { $script:ownsInstance = $script:instanceMutex.WaitOne(0) }
catch [Threading.AbandonedMutexException] { $script:ownsInstance = $true }
if (-not $script:ownsInstance) {
    [Windows.Forms.MessageBox]::Show("APEIRON OBS Overlay is already running. Open Settings from its tray icon.", "APEIRON OBS Overlay") | Out-Null
    $script:instanceMutex.Dispose()
    exit 0
}

# ---------------- Native / overlay window ----------------
$native = @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public static class ApeironNative {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);

    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x20;
    public const int WS_EX_TOOLWINDOW = 0x80;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;
}


public static class ApeironGlobalInput {
    private const int WH_KEYBOARD_LL = 13;
    private const int WH_MOUSE_LL = 14;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_LBUTTONUP = 0x0202;
    private const int WM_RBUTTONDOWN = 0x0204;
    private const int WM_RBUTTONUP = 0x0205;
    private const int WM_MBUTTONDOWN = 0x0207;
    private const int WM_MBUTTONUP = 0x0208;
    private const int WM_XBUTTONDOWN = 0x020B;
    private const int WM_XBUTTONUP = 0x020C;

    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError=true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    private static HookProc keyboardProc = KeyboardHook;
    private static HookProc mouseProc = MouseHook;
    private static IntPtr keyboardHook = IntPtr.Zero;
    private static IntPtr mouseHook = IntPtr.Zero;
    private static readonly object sync = new object();
    private static readonly bool[] states = new bool[256];
    private static readonly bool[] presses = new bool[256];
    private static System.Threading.Thread worker;
    private static uint workerId;
    private static readonly System.Threading.ManualResetEvent ready = new System.Threading.ManualResetEvent(false);

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG {
        public IntPtr hwnd; public uint message; public UIntPtr wParam;
        public IntPtr lParam; public uint time; public POINT pt; public uint lPrivate;
    }
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG msg);
    [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint id, uint msg, UIntPtr wp, IntPtr lp);

    public static bool Start() {
        if (worker != null) return keyboardHook != IntPtr.Zero && mouseHook != IntPtr.Zero;
        ready.Reset();
        worker = new System.Threading.Thread(Pump);
        worker.IsBackground = true;
        worker.Start();
        ready.WaitOne(1500);
        return keyboardHook != IntPtr.Zero && mouseHook != IntPtr.Zero;
    }

    private static void Pump() {
        workerId = GetCurrentThreadId();
        IntPtr module = IntPtr.Zero;
        try {
            using (System.Diagnostics.Process p = System.Diagnostics.Process.GetCurrentProcess()) {
                if (p.MainModule != null) module = GetModuleHandle(p.MainModule.ModuleName);
            }
        } catch {}
        keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, keyboardProc, module, 0);
        mouseHook = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, module, 0);
        ready.Set();
        try {
            MSG msg;
            while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) {
                TranslateMessage(ref msg); DispatchMessage(ref msg);
            }
        } finally {
            if (keyboardHook != IntPtr.Zero) UnhookWindowsHookEx(keyboardHook);
            if (mouseHook != IntPtr.Zero) UnhookWindowsHookEx(mouseHook);
            keyboardHook = mouseHook = IntPtr.Zero;
        }
    }

    public static void Stop() {
        if (worker != null) {
            PostThreadMessage(workerId, 0x0012, UIntPtr.Zero, IntPtr.Zero);
            worker.Join(1500); worker = null;
        }
        ClearPresses();
    }

    public static bool IsDown(int vk) {
        if (vk <= 0 || vk >= 256) return false;
        // A missed hook key-up must never latch Hold.
        return (GetAsyncKeyState(vk) & 0x8000) != 0;
    }

    public static bool ConsumePress(int vk) {
        if (vk <= 0 || vk >= 256) return false;
        lock (sync) { bool result = presses[vk]; presses[vk] = false; return result; }
    }

    public static void ClearPresses() {
        lock (sync) { Array.Clear(presses, 0, presses.Length); Array.Clear(states, 0, states.Length); }
    }

    private static void SetState(int vk, bool down) {
        if (vk <= 0 || vk >= 256) return;
        lock (sync) { if (down && !states[vk]) presses[vk] = true; states[vk] = down; }
    }

    private static IntPtr KeyboardHook(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            int msg = wParam.ToInt32();
            int vk = Marshal.ReadInt32(lParam);
            if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) SetState(vk, true);
            else if (msg == WM_KEYUP || msg == WM_SYSKEYUP) SetState(vk, false);
        }
        return CallNextHookEx(keyboardHook, nCode, wParam, lParam);
    }

    private static IntPtr MouseHook(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            int msg = wParam.ToInt32();
            if (msg == WM_LBUTTONDOWN) SetState(0x01, true);
            else if (msg == WM_LBUTTONUP) SetState(0x01, false);
            else if (msg == WM_RBUTTONDOWN) SetState(0x02, true);
            else if (msg == WM_RBUTTONUP) SetState(0x02, false);
            else if (msg == WM_MBUTTONDOWN) SetState(0x04, true);
            else if (msg == WM_MBUTTONUP) SetState(0x04, false);
            else if (msg == WM_XBUTTONDOWN || msg == WM_XBUTTONUP) {
                MSLLHOOKSTRUCT info = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                int xButton = (int)((info.mouseData >> 16) & 0xffff);
                int vk = xButton == 1 ? 0x05 : 0x06;
                SetState(vk, msg == WM_XBUTTONDOWN);
            }
        }
        return CallNextHookEx(mouseHook, nCode, wParam, lParam);
    }
}


public static class ApeironProcessSecurity {
    private const UInt32 PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const UInt32 TOKEN_QUERY = 0x0008;
    private const int TokenElevation = 20;

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_ELEVATION {
        public int TokenIsElevated;
    }

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern IntPtr OpenProcess(UInt32 dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool OpenProcessToken(IntPtr ProcessHandle, UInt32 DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool GetTokenInformation(IntPtr TokenHandle, int TokenInformationClass,
        IntPtr TokenInformation, int TokenInformationLength, out int ReturnLength);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr hObject);

    public static bool IsElevated(int pid) {
        IntPtr process = IntPtr.Zero;
        IntPtr token = IntPtr.Zero;
        IntPtr buffer = IntPtr.Zero;
        try {
            process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (process == IntPtr.Zero) return false;
            if (!OpenProcessToken(process, TOKEN_QUERY, out token)) return false;
            int size = Marshal.SizeOf(typeof(TOKEN_ELEVATION));
            buffer = Marshal.AllocHGlobal(size);
            int ret;
            if (!GetTokenInformation(token, TokenElevation, buffer, size, out ret)) return false;
            TOKEN_ELEVATION elevation = (TOKEN_ELEVATION)Marshal.PtrToStructure(buffer, typeof(TOKEN_ELEVATION));
            return elevation.TokenIsElevated != 0;
        } catch {
            return false;
        } finally {
            if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
            if (token != IntPtr.Zero) CloseHandle(token);
            if (process != IntPtr.Zero) CloseHandle(process);
        }
    }
}

public class ApeironOverlayForm : Form {
    public Color FillColor = Color.Red;
    public Color IconColor = Color.White;
    public string ShapeName = "Circle";
    public string IconKind = "Muted";
    public bool PlacementMode = false;

    private Point dragStart;
    private bool dragging = false;

    public ApeironOverlayForm() {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.Black;
        DoubleBuffered = true;
        Width = 72;
        Height = 72;
        Opacity = 0.88;
        UpdateRegion();
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= ApeironNative.WS_EX_TOOLWINDOW | ApeironNative.WS_EX_NOACTIVATE;
            if (!PlacementMode) cp.ExStyle |= ApeironNative.WS_EX_TRANSPARENT;
            return cp;
        }
    }

    public void ForceTopMost() {
        if (IsHandleCreated) {
            ApeironNative.SetWindowPos(
                Handle, ApeironNative.HWND_TOPMOST, 0,0,0,0,
                ApeironNative.SWP_NOMOVE | ApeironNative.SWP_NOSIZE |
                ApeironNative.SWP_NOACTIVATE | ApeironNative.SWP_SHOWWINDOW
            );
        }
    }

    public void SetPlacementMode(bool enabled) {
        PlacementMode = enabled;
        if (!IsHandleCreated) return;
        int ex = ApeironNative.GetWindowLong(Handle, ApeironNative.GWL_EXSTYLE);
        if (enabled) ex &= ~ApeironNative.WS_EX_TRANSPARENT;
        else ex |= ApeironNative.WS_EX_TRANSPARENT;
        ex |= ApeironNative.WS_EX_TOOLWINDOW | ApeironNative.WS_EX_NOACTIVATE;
        ApeironNative.SetWindowLong(Handle, ApeironNative.GWL_EXSTYLE, ex);
        Cursor = enabled ? Cursors.SizeAll : Cursors.Default;
        Invalidate();
    }

    public void UpdateRegion() {
        if (Width <= 0 || Height <= 0) return;
        Rectangle r = new Rectangle(0, 0, Width, Height);
        GraphicsPath gp = new GraphicsPath();
        if (ShapeName == "Square") {
            gp.AddRectangle(r);
        } else if (ShapeName == "Rounded square") {
            int radius = Math.Max(8, Math.Min(Width, Height) / 5);
            int d = radius * 2;
            gp.AddArc(0, 0, d, d, 180, 90);
            gp.AddArc(Width-d-1, 0, d, d, 270, 90);
            gp.AddArc(Width-d-1, Height-d-1, d, d, 0, 90);
            gp.AddArc(0, Height-d-1, d, d, 90, 90);
            gp.CloseFigure();
        } else {
            gp.AddEllipse(r);
        }
        Region old = Region;
        Region = new Region(gp);
        if (old != null) old.Dispose();
        gp.Dispose();
        Invalidate();
    }

    protected override void OnResize(EventArgs e) {
        base.OnResize(e);
        UpdateRegion();
    }

    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        if (PlacementMode && e.Button == MouseButtons.Left) {
            dragging = true;
            dragStart = e.Location;
        }
    }

    protected override void OnMouseMove(MouseEventArgs e) {
        base.OnMouseMove(e);
        if (PlacementMode && dragging) {
            Point screen = PointToScreen(e.Location);
            Location = new Point(screen.X - dragStart.X, screen.Y - dragStart.Y);
        }
    }

    protected override void OnMouseUp(MouseEventArgs e) {
        base.OnMouseUp(e);
        dragging = false;
    }

    private void DrawMic(Graphics g, bool slash) {
        float w = Width;
        float h = Height;
        float s = Math.Min(w,h);
        float lw = Math.Max(2f, s * 0.055f);

        using (Pen p = new Pen(IconColor, lw)) {
            p.StartCap = LineCap.Round;
            p.EndCap = LineCap.Round;

            RectangleF capsule = new RectangleF(w*0.39f, h*0.22f, w*0.22f, h*0.34f);
            using (GraphicsPath mic = new GraphicsPath()) {
                float rad = capsule.Width/2f;
                mic.AddArc(capsule.X, capsule.Y, capsule.Width, capsule.Width, 180, 180);
                mic.AddLine(capsule.Right, capsule.Y+rad, capsule.Right, capsule.Bottom-rad);
                mic.AddArc(capsule.X, capsule.Bottom-capsule.Width, capsule.Width, capsule.Width, 0, 180);
                mic.AddLine(capsule.X, capsule.Bottom-rad, capsule.X, capsule.Y+rad);
                g.DrawPath(p, mic);
            }

            g.DrawArc(p, w*0.30f, h*0.35f, w*0.40f, h*0.30f, 0, 180);
            g.DrawLine(p, w*0.50f, h*0.65f, w*0.50f, h*0.76f);
            g.DrawLine(p, w*0.39f, h*0.76f, w*0.61f, h*0.76f);

            if (slash) {
                using (Pen sp = new Pen(IconColor, lw*1.25f)) {
                    sp.StartCap = LineCap.Round; sp.EndCap = LineCap.Round;
                    g.DrawLine(sp, w*0.25f, h*0.23f, w*0.75f, h*0.78f);
                }
            }

        }
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(FillColor);

        DrawMic(g, IconKind == "Muted");

        if (PlacementMode) {
            using (Pen p = new Pen(Color.White, Math.Max(1, Width/48f))) {
                p.DashStyle = DashStyle.Dash;
                g.DrawRectangle(p, 2, 2, Width-5, Height-5);
            }
        }
    }
}
"@
Add-Type -TypeDefinition $native -ReferencedAssemblies System.Windows.Forms,System.Drawing
try { [void][ApeironNative]::SetCurrentProcessExplicitAppUserModelID("APEIRON.OBSOverlay") } catch {}

# ---------------- Paths / config ----------------
$appName = "APEIRON OBS Overlay"
$baseDir = Join-Path $env:LOCALAPPDATA "APEIRON_OBS_Overlay"
$configPath = Join-Path $baseDir "settings.json"
New-Item -ItemType Directory -Force -Path $baseDir | Out-Null

function Default-Config {
    [ordered]@{
        version = "0.2-beta1"
        schemaVersion = 6
        obs = [ordered]@{
            host = "127.0.0.1"
            port = 4455
            passwordProtected = ""
            rememberPassword = $true
            autoConnect = $true
            inputName = ""
        }
        toggle = [ordered]@{
            enabled = $true
            key = "F9"
            vk = 0x78
            overlayBehavior = "Show on change"
            duration = 2.5
        }
        hold = [ordered]@{
            enabled = $true
            key = "F10"
            vk = 0x79
            overlayBehavior = "Always show while held"
        }
        appearance = [ordered]@{
            shape = "Circle"
            size = 72
            opacity = 88
            x = 50
            y = 50
            monitor = "Primary monitor"
            mutedColor = "#D23B3B"
            unmutedColor = "#2FA866"
            iconColor = "#FFFFFF"
        }
        general = [ordered]@{
            startWithWindows = $false
            startMinimized = $false
            setupCompleted = $false
        }
    }
}

function Load-Config {
    $d = Default-Config
    if (Test-Path $configPath) {
        try {
            $c = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $schema = if ($null -ne $c.schemaVersion) { [int]$c.schemaVersion } else { 0 }

            foreach ($section in @("obs","appearance","general")) {
                if ($null -ne $c.$section) {
                    foreach ($p in $c.$section.PSObject.Properties) {
                        if ($d[$section].Contains($p.Name)) {
                            $d[$section][$p.Name] = $p.Value
                        }
                    }
                }
            }

            # Toggle settings are stable from schema 4 onward.
            if ($schema -ge 4 -and $null -ne $c.toggle) {
                foreach ($p in $c.toggle.PSObject.Properties) {
                    if ($d.toggle.Contains($p.Name)) {
                        $d.toggle[$p.Name] = $p.Value
                    }
                }
            }

            if ($schema -ge 5 -and $null -ne $c.hold) {
                foreach ($p in $c.hold.PSObject.Properties) {
                    if ($d.hold.Contains($p.Name)) {
                        $d.hold[$p.Name] = $p.Value
                    }
                }
            } elseif ($schema -eq 4 -and $null -ne $c.hold) {
                # Hotfix 4/5 -> unified Hold overlay behavior.
                if ($null -ne $c.hold.enabled) { $d.hold.enabled = [bool]$c.hold.enabled }
                if ($null -ne $c.hold.key) { $d.hold.key = [string]$c.hold.key }
                if ($null -ne $c.hold.vk) { $d.hold.vk = [int]$c.hold.vk }

                switch ([string]$c.hold.startBehavior) {
                    "Don't show" { $d.hold.overlayBehavior = "Don't show" }
                    "Show briefly" { $d.hold.overlayBehavior = "Follow normal overlay rules" }
                    default { $d.hold.overlayBehavior = "Keep visible while held" }
                }
            } else {
                # Older prototype control semantics are intentionally reset.
                $d.general.setupCompleted = $false
            }
        } catch { $script:configNotice = "Settings could not be read; defaults loaded. A backup is kept on Save." }
    }
    if ($d.hold.overlayBehavior -eq "Keep visible while held") { $d.hold.overlayBehavior = "Always show while held" }
    if ($d.hold.overlayBehavior -eq "Don't show") { $d.hold.overlayBehavior = "Don't show during Hold" }
    $validToggle = @("Show on change","Show only when muted","Show only when unmuted","Keep visible while muted","Never show")
    $validHold = @("Follow normal overlay rules","Always show while held","Don't show during Hold")
    if ($d.toggle.overlayBehavior -notin $validToggle) { $d.toggle.overlayBehavior = "Show on change" }
    if ($d.hold.overlayBehavior -notin $validHold) { $d.hold.overlayBehavior = "Always show while held" }
    if ($d.appearance.shape -notin @("Circle","Rounded square","Square")) { $d.appearance.shape = "Circle" }
    foreach ($entry in @(
        @("obs","port",1,65535,4455),
        @("toggle","duration",0.2,10,2.5),
        @("toggle","vk",1,254,120),
        @("hold","vk",1,254,121),
        @("appearance","size",32,220,72),
        @("appearance","opacity",15,100,88),
        @("appearance","x",-10000,10000,50),
        @("appearance","y",-10000,10000,50)
    )) {
        try {
            $n = [double]$d[$entry[0]][$entry[1]]
            if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { throw "Invalid number" }
            $d[$entry[0]][$entry[1]] = [Math]::Min([double]$entry[3], [Math]::Max([double]$entry[2], $n))
        } catch { $d[$entry[0]][$entry[1]] = $entry[4] }
    }
    foreach ($entry in @(@("obs","port"),@("toggle","vk"),@("hold","vk"),@("appearance","size"),@("appearance","opacity"),@("appearance","x"),@("appearance","y"))) {
        $d[$entry[0]][$entry[1]] = [int]$d[$entry[0]][$entry[1]]
    }
    if ($d.toggle.enabled -and $d.hold.enabled -and $d.toggle.vk -eq $d.hold.vk) {
        $d.hold.enabled = $false
        $script:configNotice = "Hold disabled: assign different Toggle and Hold keys."
    }
    return $d
}

function Save-Config($cfg) {
    $tmp = $configPath + ".tmp"
    $cfg | ConvertTo-Json -Depth 7 | Set-Content $tmp -Encoding UTF8
    if (Test-Path $configPath) {
        [IO.File]::Replace($tmp, $configPath, ($configPath + ".bak"))
    } else {
        [IO.File]::Move($tmp, $configPath)
    }
}

function Protect-Password([string]$plain) {
    if ([string]::IsNullOrEmpty($plain)) { return "" }
    try {
        $sec = ConvertTo-SecureString $plain -AsPlainText -Force
        return ConvertFrom-SecureString $sec
    } catch { return "" }
}

function Unprotect-Password([string]$protected) {
    if ([string]::IsNullOrEmpty($protected)) { return "" }
    try {
        $sec = ConvertTo-SecureString $protected
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { return "" }
}

$script:firstRun = -not (Test-Path $configPath)
$cfg = Load-Config

# ---------------- WebSocket helpers ----------------
$script:ws = $null
$script:reqId = 0
$script:connected = $false
$script:lastMute = $null
$script:lastReconnect = [datetime]::MinValue
$script:lastInputRefresh = [datetime]::MinValue
$script:inputReady = $false
$script:refreshingInputs = $false
$script:sessionPassword = Unprotect-Password $cfg.obs.passwordProtected
$script:passwordRequired = $false
$script:connectionError = ""
$script:pendingRestore = $null

function WS-SendObject($obj) {
    $json = $obj | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object ArraySegment[byte] -ArgumentList (, $bytes)
    $ct = [Threading.CancellationToken]::None
    $task = $script:ws.SendAsync($seg, [Net.WebSockets.WebSocketMessageType]::Text, $true, $ct)
    if (-not $task.Wait(2500)) { throw "WebSocket send timeout" }
}

function WS-ReceiveObject([int]$timeoutMs = 3000) {
    $buffer = New-Object byte[] 8192
    $ms = New-Object IO.MemoryStream
    $ct = New-Object Threading.CancellationTokenSource
    $ct.CancelAfter($timeoutMs)
    try {
        do {
            $seg = New-Object ArraySegment[byte] -ArgumentList (, $buffer)
            $task = $script:ws.ReceiveAsync($seg, $ct.Token)
            $task.Wait()
            $res = $task.Result
            if ($res.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                if ([int]$res.CloseStatus -eq 4009) { throw "OBS authentication failed" }
                throw "WebSocket closed"
            }
            $ms.Write($buffer, 0, $res.Count)
        } while (-not $res.EndOfMessage)
        $txt = [Text.Encoding]::UTF8.GetString($ms.ToArray())
        return $txt | ConvertFrom-Json
    } finally {
        $ct.Dispose()
        $ms.Dispose()
    }
}

function Test-LocalPort([string]$obsHost, [int]$port, [int]$timeout=180) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($obsHost, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeout, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false }
    finally { $client.Close() }
}

function Compute-ObsAuth([string]$password, [string]$salt, [string]$challenge) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $secretBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($password + $salt))
        $secret = [Convert]::ToBase64String($secretBytes)
        $authBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($secret + $challenge))
        return [Convert]::ToBase64String($authBytes)
    } finally { $sha.Dispose() }
}

function Disconnect-OBS {
    try {
        if ($script:ws) { $script:ws.Dispose() }
    } catch {}
    $script:ws = $null
    $script:connected = $false
    $script:inputReady = $false
    $script:lastMute = $null
    $script:baseMute = $null
    $script:holdActive = $false
    $script:holdBaseMute = $null
    if ($null -ne $overlay) { Hide-Overlay }
}

function Connect-OBS([string]$obsHost, [int]$port, [string]$password, [switch]$Quiet) {
    Disconnect-OBS
    if (-not (Test-LocalPort $obsHost $port 200)) {
        if (-not $Quiet) { throw "OBS WebSocket is not reachable at ${obsHost}:$port" }
        return $false
    }
    try {
        $script:ws = New-Object Net.WebSockets.ClientWebSocket
        $uri = New-Object Uri("ws://${obsHost}:$port")
        $ct = New-Object Threading.CancellationTokenSource
        $ct.CancelAfter(2500)
        try {
            $t = $script:ws.ConnectAsync($uri, $ct.Token); $t.Wait()
        } finally { $ct.Dispose() }

        $hello = WS-ReceiveObject 2500
        if ($hello.op -ne 0) { throw "Unexpected OBS hello" }

        $identify = [ordered]@{ op = 1; d = [ordered]@{ rpcVersion = 1; eventSubscriptions = 0 } }
        if ($null -ne $hello.d.authentication) {
            if ([string]::IsNullOrEmpty($password)) { throw "OBS WebSocket password is required" }
            $identify.d.authentication = Compute-ObsAuth $password $hello.d.authentication.salt $hello.d.authentication.challenge
        }
        WS-SendObject $identify
        $identified = WS-ReceiveObject 2500
        if ($identified.op -ne 2) { throw "OBS authentication failed" }

        $script:connected = $true
        $script:passwordRequired = $false
        $script:connectionError = ""
        return $true
    } catch {
        $script:connectionError = $_.Exception.Message
        if ($script:connectionError -match "password is required|authentication failed") { $script:passwordRequired = $true }
        Disconnect-OBS
        if (-not $Quiet) { throw }
        return $false
    }
}

function OBS-Request([string]$type, $data=$null) {
    if (-not $script:connected) { throw "Not connected to OBS" }
    $script:reqId++
    $id = "apeiron-$($script:reqId)"
    $d = [ordered]@{ requestType=$type; requestId=$id }
    if ($null -ne $data) { $d.requestData = $data }
    WS-SendObject ([ordered]@{ op=6; d=$d })
    $r = WS-ReceiveObject 2200
    if ($r.op -ne 7 -or $r.d.requestId -ne $id) { throw "Unexpected OBS response" }
    if (-not $r.d.requestStatus.result) {
        $error = New-Object InvalidOperationException ("OBS: " + $r.d.requestStatus.comment)
        $error.Data["OBSCode"] = [int]$r.d.requestStatus.code
        throw $error
    }
    return $r.d.responseData
}

function Get-ObsInputs {
    $r = OBS-Request "GetInputList"
    foreach ($input in @($r.inputs)) {
        try {
            # Capability check also works for custom and renamed audio inputs.
            $null = Get-InputMute ([string]$input.inputName)
            $input
        } catch {
            if ($null -eq $_.Exception.Data["OBSCode"]) { throw }
        }
    }
}

function Get-InputMute([string]$name) {
    $r = OBS-Request "GetInputMute" ([ordered]@{ inputName=$name })
    return [bool]$r.inputMuted
}

function Set-InputMute([string]$name, [bool]$mute) {
    OBS-Request "SetInputMute" ([ordered]@{ inputName=$name; inputMuted=$mute }) | Out-Null
    $script:lastMute = $mute
}

# ---------------- Key mapping / capture ----------------
function Vk-ToName([int]$vk) {
    switch ($vk) {
        0x01 { return "Mouse1 / Left" }
        0x02 { return "Mouse2 / Right" }
        0x04 { return "Mouse3 / Middle" }
        0x05 { return "Mouse4 / X1" }
        0x06 { return "Mouse5 / X2" }
        0x10 { return "Shift" }
        0x11 { return "Ctrl" }
        0x12 { return "Alt" }
        0xA0 { return "Left Shift" }
        0xA1 { return "Right Shift" }
        0xA2 { return "Left Ctrl" }
        0xA3 { return "Right Ctrl" }
        0xA4 { return "Left Alt" }
        0xA5 { return "Right Alt" }
    }
    try {
        $k = [System.Windows.Forms.Keys]$vk
        $s = $k.ToString()
        if (-not [string]::IsNullOrWhiteSpace($s) -and $s -ne "None") { return $s }
    } catch {}
    return ("VK 0x{0:X2}" -f $vk)
}

function Vk-IsDown([int]$vk) {
    if ($vk -le 0 -or $vk -gt 254) { return $false }
    return [ApeironGlobalInput]::IsDown($vk)
}

$script:keyCaptureActive = $false

function Capture-Key([string]$title) {
    if ($script:holdActive) { Hold-Release }
    $script:keyCaptureActive = $true
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = $title
    $dlg.Width = 390
    $dlg.Height = 165
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.TopMost = $true

    $label = New-Object Windows.Forms.Label
    $label.Left = 20
    $label.Top = 20
    $label.Width = 340
    $label.Height = 58
    $label.TextAlign = "MiddleCenter"
    $label.Text = "Release all keys, then press the keyboard or mouse button you want to use."
    $dlg.Controls.Add($label)

    $cancel = New-Object Windows.Forms.Button
    $cancel.Left = 145
    $cancel.Top = 88
    $cancel.Width = 90
    $cancel.Height = 28
    $cancel.Text = "Cancel"
    $cancel.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($cancel)

    $captured = 0
    $releaseTicks = 0
    $armed = $false

    try {
        if ($null -ne $form) { $form.Enabled = $false }
        $dlg.Show()

        while ($dlg.Visible) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 18

            if (-not $armed) {
                $anyDown = $false
                for ($vk = 1; $vk -le 254; $vk++) {
                    if (Vk-IsDown $vk) { $anyDown = $true; break }
                }
                if (-not $anyDown) {
                    $releaseTicks++
                    if ($releaseTicks -ge 3) {
                        $armed = $true
                        $label.Text = "Press any keyboard or mouse button..."
                    }
                } else {
                    $releaseTicks = 0
                }
                continue
            }

            if ($captured -eq 0) {
                for ($vk = 1; $vk -le 254; $vk++) {
                    if (Vk-IsDown $vk) {
                        $captured = $vk
                        $label.Text = ("Selected: " + (Vk-ToName $captured) + "`r`nRelease it to confirm.")
                        break
                    }
                }
            } else {
                if (-not (Vk-IsDown $captured)) {
                    $dlg.Close()
                    return $captured
                }
            }
        }
        return 0
    } finally {
        try { $dlg.Dispose() } catch {}
        if ($null -ne $form) { $form.Enabled = $true; $form.Activate() }
        $script:keyCaptureActive = $false
        Sync-ControlInput
    }
}

# ---------------- Overlay ----------------
$overlay = New-Object ApeironOverlayForm
$script:overlayHideAt = [datetime]::MaxValue
$script:overlayPersistent = $false
$script:placement = $false
$script:overlayWanted = $false
$script:overlayMuted = $false
$script:previewActive = $false
$script:previewUntil = [datetime]::MinValue

function Hex-ToColor([string]$hex) {
    try { return [Drawing.ColorTranslator]::FromHtml($hex) } catch { return [Drawing.Color]::White }
}

function Apply-Appearance {
    $overlay.ShapeName = [string]$cfg.appearance.shape
    $overlay.Width = [int]$cfg.appearance.size
    $overlay.Height = [int]$cfg.appearance.size
    $overlay.Opacity = [Math]::Max(0.15,[Math]::Min(1.0,[double]$cfg.appearance.opacity/100.0))
    $overlay.IconColor = Hex-ToColor $cfg.appearance.iconColor
    if (-not $script:placement) { $overlay.Location = New-Object Drawing.Point([int]$cfg.appearance.x,[int]$cfg.appearance.y) }
    $overlay.UpdateRegion()
}

function Render-Overlay([bool]$muted) {
    Apply-Appearance
    if ($muted) {
        $overlay.IconKind = "Muted"
        $overlay.FillColor = Hex-ToColor $cfg.appearance.mutedColor
    } else {
        $overlay.IconKind = "Unmuted"
        $overlay.FillColor = Hex-ToColor $cfg.appearance.unmutedColor
    }
    $overlay.Invalidate()
    if (-not $overlay.Visible) { $overlay.Show() }
    $overlay.ForceTopMost()
}

function Show-Overlay([bool]$muted, [double]$seconds, [bool]$persistent=$false) {
    $script:overlayWanted = $true
    $script:overlayMuted = $muted
    $script:overlayPersistent = $persistent
    if ($persistent) {
        $script:overlayHideAt = [datetime]::MaxValue
    } else {
        $script:overlayHideAt = (Get-Date).AddSeconds([Math]::Max(0.1,$seconds))
    }
    if (-not $script:placement -and -not $script:previewActive) { Render-Overlay $muted }
}

function Hide-Overlay {
    $script:overlayWanted = $false
    $script:overlayPersistent = $false
    $script:overlayHideAt = [datetime]::MaxValue
    if (-not $script:placement -and -not $script:previewActive) {
        $overlay.Hide()
    }
}

function Show-Preview([bool]$muted) {
    if ($script:placement) { return }
    $script:previewActive = $true
    $script:previewUntil = (Get-Date).AddSeconds([double]$cfg.toggle.duration)
    Render-Overlay $muted
}

function Update-OverlayVisibility([datetime]$now = (Get-Date)) {
    if ($script:overlayWanted -and -not $script:overlayPersistent -and $now -ge $script:overlayHideAt) {
        $script:overlayWanted = $false
    }
    if ($script:placement) { $overlay.ForceTopMost(); return }
    if ($script:previewActive -and $now -lt $script:previewUntil) { $overlay.ForceTopMost(); return }
    $script:previewActive = $false
    if ($script:overlayWanted) {
        $kind=if($script:overlayMuted){"Muted"}else{"Unmuted"}
        if (-not $overlay.Visible -or $overlay.IconKind -ne $kind) { Render-Overlay $script:overlayMuted }
        else { $overlay.ForceTopMost() }
    }
    elseif ($overlay.Visible) { $overlay.Hide() }
}

function Apply-ToggleOverlay([bool]$muted) {
    switch ([string]$cfg.toggle.overlayBehavior) {
        "Show on change" {
            Show-Overlay $muted $cfg.toggle.duration $false
        }
        "Show only when muted" {
            if ($muted) { Show-Overlay $true $cfg.toggle.duration $false } else { Hide-Overlay }
        }
        "Show only when unmuted" {
            if (-not $muted) { Show-Overlay $false $cfg.toggle.duration $false } else { Hide-Overlay }
        }
        "Keep visible while muted" {
            if ($muted) { Show-Overlay $true 0 $true } else { Hide-Overlay }
        }
        default {
            Hide-Overlay
        }
    }
}

function Restore-BaseOverlay {
    if ($null -eq $script:baseMute) { Hide-Overlay; return }
    if ([string]$cfg.toggle.overlayBehavior -eq "Keep visible while muted" -and [bool]$script:baseMute) {
        Show-Overlay $true 0 $true
    } else {
        Hide-Overlay
    }
}

function Apply-HoldOverlay {
    $effective = -not [bool]$script:holdBaseMute
    switch ([string]$cfg.hold.overlayBehavior) {
        "Follow normal overlay rules" { Apply-ToggleOverlay $effective }
        "Always show while held" { Show-Overlay $effective 0 $true }
        default { Hide-Overlay }
    }
}

function Reconcile-Overlay {
    if ($script:holdActive) { Apply-HoldOverlay }
    else { Restore-BaseOverlay }
}

Apply-Appearance

# ---------------- UI helpers ----------------
function New-Label($text,$x,$y,$w=180,$h=22) {
    $c = New-Object Windows.Forms.Label
    $c.Text=$text; $c.Left=$x; $c.Top=$y; $c.Width=$w; $c.Height=$h
    return $c
}
function New-Check($text,$x,$y,$w=300) {
    $c=New-Object Windows.Forms.CheckBox
    $c.Text=$text; $c.Left=$x; $c.Top=$y; $c.Width=$w
    return $c
}
function New-Button($text,$x,$y,$w=120) {
    $c=New-Object Windows.Forms.Button
    $c.Text=$text; $c.Left=$x; $c.Top=$y; $c.Width=$w; $c.Height=30
    return $c
}
function New-Num($x,$y,$min,$max,$dec=0,$inc=1,$w=90) {
    $c=New-Object Windows.Forms.NumericUpDown
    $c.Left=$x; $c.Top=$y; $c.Width=$w; $c.Minimum=$min; $c.Maximum=$max
    $c.DecimalPlaces=$dec; $c.Increment=$inc
    return $c
}
function New-ColorButton($x,$y,$hex) {
    $b=New-Object Windows.Forms.Button
    $b.Left=$x; $b.Top=$y; $b.Width=90; $b.Height=28; $b.Text=$hex
    $b.BackColor=Hex-ToColor $hex
    $b.ForeColor=if (($b.BackColor.R+$b.BackColor.G+$b.BackColor.B) -lt 350) {[Drawing.Color]::White} else {[Drawing.Color]::Black}
    return $b
}
function New-Radio($text,$tag,$x,$y,$w=230) {
    $r=New-Object Windows.Forms.RadioButton
    $r.Text=$text; $r.Tag=$tag; $r.Left=$x; $r.Top=$y; $r.Width=$w
    return $r
}
function Choose-Color($button) {
    $d=New-Object Windows.Forms.ColorDialog
    $d.Color=$button.BackColor
    if ($d.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $button.BackColor=$d.Color
        $button.Text=("#{0:X2}{1:X2}{2:X2}" -f $d.Color.R,$d.Color.G,$d.Color.B)
        $button.ForeColor=if (($d.Color.R+$d.Color.G+$d.Color.B) -lt 350) {[Drawing.Color]::White} else {[Drawing.Color]::Black}
    }
}
function Get-SelectedTag($radios,$fallback) {
    foreach ($r in $radios) { if ($r.Checked) { return [string]$r.Tag } }
    return $fallback
}
function Select-RadioByTag($radios,[string]$tag) {
    foreach ($r in $radios) { $r.Checked = ([string]$r.Tag -eq $tag) }
}
function Open-Url([string]$url) {
    if ([string]::IsNullOrWhiteSpace($url)) {
        [Windows.Forms.MessageBox]::Show(
            "The APEIRON website link has not been inserted into this beta1 build yet.",
            "APEIRON OBS Overlay",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }
    try { Start-Process $url } catch {}
}

# ---------------- App constants ----------------
$appVersion = "0.2 beta1 — build 4"
$iconPath = Join-Path $PSScriptRoot "APEIRON.ico"
$aboutImagePath = Join-Path $PSScriptRoot "APEIRON_icon.png"
$authorWebsite = "https://apeiron.framer.media/"
$authorPayPal = "https://www.paypal.com/paypalme/StanislavMed"

# ---------------- Main form ----------------
$form = New-Object Windows.Forms.Form
$form.Text = "APEIRON OBS Overlay v0.2 beta1 — build 4"
$form.Font = New-Object Drawing.Font("Segoe UI",9)
$form.AutoScaleMode = "Font"
$form.Width = 650
$form.Height = 735
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "Sizable"
$form.MinimumSize = New-Object Drawing.Size(650,520)
$form.MaximizeBox = $false
$form.MinimizeBox = $true
if (Test-Path $iconPath) {
    try { $form.Icon = New-Object Drawing.Icon($iconPath) }
    catch { $form.Icon = [Drawing.SystemIcons]::Application }
} else {
    $form.Icon = [Drawing.SystemIcons]::Application
}

$tabs = New-Object Windows.Forms.TabControl
$tabs.Left=10; $tabs.Top=10; $tabs.Width=610; $tabs.Height=610
$tabs.Anchor = "Top,Bottom,Left,Right"
$form.Controls.Add($tabs)

$tabControls = New-Object Windows.Forms.TabPage; $tabControls.Text="Controls"
$tabControls.AutoScroll=$true
$tabLook = New-Object Windows.Forms.TabPage; $tabLook.Text="Appearance"
$tabObs = New-Object Windows.Forms.TabPage; $tabObs.Text="OBS"
$tabGeneral = New-Object Windows.Forms.TabPage; $tabGeneral.Text="General"
$tabAbout = New-Object Windows.Forms.TabPage; $tabAbout.Text="About / Support"
foreach ($tab in @($tabLook,$tabObs,$tabGeneral,$tabAbout)) { $tab.AutoScroll = $true }
$tabs.TabPages.AddRange(@($tabControls,$tabLook,$tabObs,$tabGeneral,$tabAbout))

# ---------------- Controls tab ----------------
$grpMic=New-Object Windows.Forms.GroupBox
$grpMic.Text="Microphone controls"
$grpMic.Left=15;$grpMic.Top=15;$grpMic.Width=565;$grpMic.Height=210
$tabControls.Controls.Add($grpMic)

$chkToggle=New-Check "Enable Mute / Unmute hotkey" 20 30 245
$chkToggle.Checked=[bool]$cfg.toggle.enabled
$grpMic.Controls.Add($chkToggle)

$grpMic.Controls.Add((New-Label "Toggle key" 35 68 90))
$script:toggleVk=[int]$cfg.toggle.vk
if ($script:toggleVk -le 0) { $script:toggleVk=0x78 }
$txtToggleKey=New-Object Windows.Forms.TextBox
$txtToggleKey.Left=130;$txtToggleKey.Top=65;$txtToggleKey.Width=150;$txtToggleKey.ReadOnly=$true
$txtToggleKey.Text=(Vk-ToName $script:toggleVk)
$grpMic.Controls.Add($txtToggleKey)
$btnSetToggle=New-Button "Set key..." 295 63 90
$grpMic.Controls.Add($btnSetToggle)

$chkHold=New-Check "Enable Hold Mode" 20 105 220
$chkHold.Checked=[bool]$cfg.hold.enabled
$grpMic.Controls.Add($chkHold)

$grpMic.Controls.Add((New-Label "Hold key" 35 143 90))
$script:holdVk=[int]$cfg.hold.vk
if ($script:holdVk -le 0) { $script:holdVk=0x79 }
$txtHoldKey=New-Object Windows.Forms.TextBox
$txtHoldKey.Left=130;$txtHoldKey.Top=140;$txtHoldKey.Width=150;$txtHoldKey.ReadOnly=$true
$txtHoldKey.Text=(Vk-ToName $script:holdVk)
$grpMic.Controls.Add($txtHoldKey)
$btnSetHold=New-Button "Set key..." 295 138 90
$grpMic.Controls.Add($btnSetHold)

$lblControlLogic=New-Label "Mute / Unmute changes the base state. Hold Mode temporarily uses the opposite state and restores the base state when released. While Hold is active, Toggle is paused." 20 172 520 34
$grpMic.Controls.Add($lblControlLogic)

$grpOverlay=New-Object Windows.Forms.GroupBox
$grpOverlay.Text="Overlay behavior"
$grpOverlay.Left=15;$grpOverlay.Top=240;$grpOverlay.Width=565;$grpOverlay.Height=325
$tabControls.Controls.Add($grpOverlay)

$grpOverlay.Controls.Add((New-Label "Normal microphone changes" 20 30 220))
$toggleRadios=@(
    (New-Radio "Show on change" "Show on change" 35 58 205),
    (New-Radio "Show only when muted" "Show only when muted" 275 58 230),
    (New-Radio "Show only when unmuted" "Show only when unmuted" 35 85 220),
    (New-Radio "Keep visible while muted" "Keep visible while muted" 275 85 230),
    (New-Radio "Don't show for normal changes" "Never show" 35 112 280)
)
$normalRadioPanel = New-Object Windows.Forms.Panel
$normalRadioPanel.Left=10; $normalRadioPanel.Top=48; $normalRadioPanel.Width=540; $normalRadioPanel.Height=90
$grpOverlay.Controls.Add($normalRadioPanel)
foreach($r in $toggleRadios){$r.Left-=10; $r.Top-=48; $normalRadioPanel.Controls.Add($r)}
Select-RadioByTag $toggleRadios ([string]$cfg.toggle.overlayBehavior)

$grpOverlay.Controls.Add((New-Label "Popup duration" 35 148 105))
$numToggleDur=New-Num 145 145 0.2 10 1 0.1 85
$numToggleDur.Value=[decimal]$cfg.toggle.duration
$grpOverlay.Controls.Add($numToggleDur)
$grpOverlay.Controls.Add((New-Label "sec." 235 148 45))
$grpOverlay.Controls.Add((New-Label "Used by brief popup modes; ignored by persistent / never-show modes." 290 142 245 42))

$grpOverlay.Controls.Add((New-Label "During Hold Mode" 20 193 180))
$holdRadios=@(
    (New-Radio "Follow normal overlay rules" "Follow normal overlay rules" 25 0 250),
    (New-Radio "Always show while held" "Always show while held" 280 0 235),
    (New-Radio "Don't show during Hold" "Don't show during Hold" 25 28 250)
)
$holdRadioPanel = New-Object Windows.Forms.Panel
$holdRadioPanel.Left=10; $holdRadioPanel.Top=215; $holdRadioPanel.Width=540; $holdRadioPanel.Height=57
$grpOverlay.Controls.Add($holdRadioPanel)
foreach($r in $holdRadios){$holdRadioPanel.Controls.Add($r)}
Select-RadioByTag $holdRadios ([string]$cfg.hold.overlayBehavior)

$grpOverlay.Controls.Add((New-Label "Releasing Hold restores the base microphone state and its persistent overlay. It does not create a popup." 35 283 500 36))

# ---------------- Appearance tab ----------------
$tabLook.Controls.Add((New-Label "Shape" 20 25 100))
$cmbShape=New-Object Windows.Forms.ComboBox
$cmbShape.Left=135;$cmbShape.Top=22;$cmbShape.Width=160;$cmbShape.DropDownStyle="DropDownList"
[void]$cmbShape.Items.AddRange([object[]]@("Circle","Rounded square","Square"))
$cmbShape.SelectedItem=[string]$cfg.appearance.shape
$tabLook.Controls.Add($cmbShape)

$tabLook.Controls.Add((New-Label "Size, px" 20 65 100))
$numSize=New-Num 135 62 32 220 0 1 90
$numSize.Value=[decimal]$cfg.appearance.size
$tabLook.Controls.Add($numSize)

$tabLook.Controls.Add((New-Label "Opacity, %" 20 105 100))
$numOpacity=New-Num 135 102 15 100 0 1 90
$numOpacity.Value=[decimal]$cfg.appearance.opacity
$tabLook.Controls.Add($numOpacity)

$tabLook.Controls.Add((New-Label "Mic MUTED" 330 25 90))
$btnMutedColor=New-ColorButton 430 20 $cfg.appearance.mutedColor
$tabLook.Controls.Add($btnMutedColor)
$tabLook.Controls.Add((New-Label "Mic ON" 330 65 90))
$btnUnmutedColor=New-ColorButton 430 60 $cfg.appearance.unmutedColor
$tabLook.Controls.Add($btnUnmutedColor)
$tabLook.Controls.Add((New-Label "Icon" 330 105 90))
$btnIconColor=New-ColorButton 430 100 $cfg.appearance.iconColor
$tabLook.Controls.Add($btnIconColor)

$tabLook.Controls.Add((New-Label "Position X" 20 170 100))
$numX=New-Num 135 167 -10000 10000 0 1 105
$numX.Value=[decimal]$cfg.appearance.x
$tabLook.Controls.Add($numX)
$tabLook.Controls.Add((New-Label "Position Y" 20 210 100))
$numY=New-Num 135 207 -10000 10000 0 1 105
$numY.Value=[decimal]$cfg.appearance.y
$tabLook.Controls.Add($numY)

$tabLook.Controls.Add((New-Label "Preset monitor" 330 170 95))
$cmbMonitor=New-Object Windows.Forms.ComboBox
$cmbMonitor.Left=430;$cmbMonitor.Top=167;$cmbMonitor.Width=135;$cmbMonitor.DropDownStyle="DropDownList"
[void]$cmbMonitor.Items.AddRange([object[]]@("Primary monitor","Last active monitor"))
$cmbMonitor.DropDownWidth=220
if ($cfg.appearance.monitor -eq "Active monitor") { $cfg.appearance.monitor="Last active monitor" }
$cmbMonitor.SelectedItem=[string]$cfg.appearance.monitor
if ($null -eq $cmbMonitor.SelectedItem) { $cmbMonitor.SelectedIndex=0 }
$tabLook.Controls.Add($cmbMonitor)

$btnPlace=New-Button "Place by dragging" 20 270 160
$script:placeBackColor=$btnPlace.BackColor
$script:placeForeColor=$btnPlace.ForeColor
$tabLook.Controls.Add($btnPlace)
$btnTopLeft=New-Button "Top-left" 195 270 95
$tabLook.Controls.Add($btnTopLeft)
$btnTopRight=New-Button "Top-right" 300 270 95
$tabLook.Controls.Add($btnTopRight)
$btnBottomLeft=New-Button "Bottom-left" 195 310 95
$tabLook.Controls.Add($btnBottomLeft)
$btnBottomRight=New-Button "Bottom-right" 300 310 105
$tabLook.Controls.Add($btnBottomRight)

$btnTestMute=New-Button "Test MUTED" 90 345 150
$tabLook.Controls.Add($btnTestMute)
$btnTestOn=New-Button "Test Mic ON" 330 345 150
$tabLook.Controls.Add($btnTestOn)
$lblPlacement=New-Label "Drag placement: click Place by dragging, move the overlay, then Finish placement." 20 405 540 45
$tabLook.Controls.Add($lblPlacement)

# ---------------- OBS tab ----------------
$tabObs.Controls.Add((New-Label "Host" 20 25 110))
$txtHost=New-Object Windows.Forms.TextBox
$txtHost.Left=145;$txtHost.Top=22;$txtHost.Width=190;$txtHost.Text=$cfg.obs.host
$tabObs.Controls.Add($txtHost)

$tabObs.Controls.Add((New-Label "Port" 20 62 110))
$numPort=New-Num 145 59 1 65535 0 1 100
$numPort.Value=[decimal]$cfg.obs.port
$tabObs.Controls.Add($numPort)

$tabObs.Controls.Add((New-Label "WebSocket password" 20 99 120))
$txtPass=New-Object Windows.Forms.TextBox
$txtPass.Left=145;$txtPass.Top=96;$txtPass.Width=190;$txtPass.UseSystemPasswordChar=$true
$txtPass.Text=(Unprotect-Password $cfg.obs.passwordProtected)
$tabObs.Controls.Add($txtPass)

$chkRemember=New-Check "Remember password (encrypted for this Windows user)" 145 130 350
$chkRemember.Checked=[bool]$cfg.obs.rememberPassword
$tabObs.Controls.Add($chkRemember)

$chkAuto=New-Check "Auto-connect when OBS becomes available" 145 158 310
$chkAuto.Checked=[bool]$cfg.obs.autoConnect
$tabObs.Controls.Add($chkAuto)

$btnConnect=New-Button "Connect / refresh" 20 205 150
$tabObs.Controls.Add($btnConnect)
$lblStatus=New-Label "Not connected" 190 211 360
$tabObs.Controls.Add($lblStatus)

$tabObs.Controls.Add((New-Label "Audio input" 20 260 110))
$cmbInput=New-Object Windows.Forms.ComboBox
$cmbInput.Left=145;$cmbInput.Top=257;$cmbInput.Width=380;$cmbInput.DropDownStyle="DropDownList"
$tabObs.Controls.Add($cmbInput)

$tabObs.Controls.Add((New-Label "Choose the microphone / Audio Input Capture source that this app should control." 20 300 535 35))

$lblElevation=New-Label "" 20 360 540 55
$lblElevation.ForeColor=[Drawing.Color]::DarkRed
$tabObs.Controls.Add($lblElevation)
$btnRestartAdmin=New-Button "Restart overlay as Administrator" 20 425 225
$btnRestartAdmin.Visible=$false
$tabObs.Controls.Add($btnRestartAdmin)
$lblPasswordHint=New-Label "Unsaved passwords are kept for this run only. After restarting the app, enter the password again." 20 475 535 50
$tabObs.Controls.Add($lblPasswordHint)

# ---------------- General tab ----------------
$chkStartup=New-Check "Start with Windows" 20 30 260
$chkStartup.Checked=[bool]$cfg.general.startWithWindows
$tabGeneral.Controls.Add($chkStartup)

$chkMinimized=New-Check "Start hidden in tray with Windows" 20 70 300
$chkMinimized.Checked=[bool]$cfg.general.startMinimized
$chkMinimized.Enabled=$chkStartup.Checked
$tabGeneral.Controls.Add($chkMinimized)
$chkStartup.Add_CheckedChanged({$chkMinimized.Enabled=$chkStartup.Checked})

$tabGeneral.Controls.Add((New-Label "Closing the settings window only hides it. Use the tray icon → Exit to stop the overlay." 20 125 540 50))

$tabGeneral.Controls.Add((New-Label "Settings:" 20 210 100))
$tabGeneral.Controls.Add((New-Label "%LOCALAPPDATA%\APEIRON_OBS_Overlay\settings.json" 20 238 520 30))
$btnOpenSettings=New-Button "Open settings folder" 20 285 165
$tabGeneral.Controls.Add($btnOpenSettings)
$btnReset=New-Button "Reset settings" 200 285 135
$tabGeneral.Controls.Add($btnReset)

$tabGeneral.Controls.Add((New-Label "The configuration is per Windows user. The app contains no OBS password, microphone name, or personal hotkeys from another user." 20 350 535 65))

# ---------------- About / Support tab ----------------
$picAbout=New-Object Windows.Forms.PictureBox
$picAbout.Left=22;$picAbout.Top=25;$picAbout.Width=96;$picAbout.Height=96
$picAbout.SizeMode="Zoom"
if (Test-Path $aboutImagePath) {
    try { $picAbout.Image=[Drawing.Image]::FromFile($aboutImagePath) } catch {}
}
$tabAbout.Controls.Add($picAbout)

$title=New-Label "APEIRON OBS Overlay" 140 30 410 38
$title.Font=New-Object Drawing.Font("Segoe UI",18,[Drawing.FontStyle]::Bold)
$tabAbout.Controls.Add($title)
$tabAbout.Controls.Add((New-Label "v0.2 beta1 — build 4" 142 72 300 26))
$tabAbout.Controls.Add((New-Label "A lightweight microphone status overlay and hotkey controller for OBS Studio." 142 105 400 50))
$tabAbout.Controls.Add((New-Label "Made by APEIRON" 142 160 250 25))

$btnWebsite=New-Button "APEIRON / Website" 22 225 220
$tabAbout.Controls.Add($btnWebsite)
$btnPaypal=New-Button "Support via PayPal" 270 225 220
$tabAbout.Controls.Add($btnPaypal)
$btnDiagnostics=New-Button "Copy diagnostics" 22 285 220
$tabAbout.Controls.Add($btnDiagnostics)


$tabAbout.Controls.Add((New-Label "Diagnostics never include the OBS WebSocket password." 22 390 500 30))

# Bottom controls
$btnSave=New-Button "Save / Apply" 265 640 140
$btnSave.Anchor="Bottom,Right"
$form.Controls.Add($btnSave)
$btnHide=New-Button "Hide to tray" 420 640 140
$btnHide.Anchor="Bottom,Right"
$form.Controls.Add($btnHide)
$lblBottom=New-Label "Ready" 15 648 235 25
$lblBottom.Anchor="Bottom,Left"
$form.Controls.Add($lblBottom)

# ---------------- Tray ----------------
$tray=New-Object Windows.Forms.NotifyIcon
if (Test-Path $iconPath) {
    try { $tray.Icon = New-Object Drawing.Icon($iconPath) }
    catch { $tray.Icon=[Drawing.SystemIcons]::Application }
} else {
    $tray.Icon=[Drawing.SystemIcons]::Application
}
$tray.Text=$appName
$tray.Visible=$true
$menu=New-Object Windows.Forms.ContextMenuStrip
$mSettings=$menu.Items.Add("Settings")
$mTestMute=$menu.Items.Add("Test MUTED")
$mTestOn=$menu.Items.Add("Test Mic ON")
[void]$menu.Items.Add("-")
$mExit=$menu.Items.Add("Exit")
$tray.ContextMenuStrip=$menu

# ---------------- State / helpers ----------------
$script:toggleWasDown=$false
$script:holdWasDown=$false
$script:holdActive=$false
$script:holdBaseMute=$null
$script:baseMute=$null
$script:hookStarted=$false
$script:reallyExit=$false
$script:elevationPromptShown=$false
$script:lastExternalScreen=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea

function Copy-OBS-UI-ToConfig {
    $nextInput=if ($cmbInput.SelectedItem) {[string]$cmbInput.SelectedItem} else {[string]$cfg.obs.inputName}
    $targetChanged=($cfg.obs.host -ne $txtHost.Text.Trim() -or $cfg.obs.port -ne [int]$numPort.Value -or $cfg.obs.inputName -ne $nextInput)
    if ($targetChanged -and $script:holdActive) { Hold-Release }
    if ($targetChanged -and $script:connected) { Disconnect-OBS }
    $cfg.obs.host=$txtHost.Text.Trim()
    $cfg.obs.port=[int]$numPort.Value
    $cfg.obs.rememberPassword=$chkRemember.Checked
    $cfg.obs.autoConnect=$chkAuto.Checked
    $cfg.obs.inputName=$nextInput
    $script:sessionPassword=$txtPass.Text
    if ($chkRemember.Checked) { $cfg.obs.passwordProtected=Protect-Password $txtPass.Text } else { $cfg.obs.passwordProtected="" }
}

function Copy-Controls-UI-ToConfig {
    $cfg.toggle.enabled=$chkToggle.Checked
    $cfg.toggle.vk=[int]$script:toggleVk
    $cfg.toggle.key=(Vk-ToName $script:toggleVk)
    $cfg.toggle.overlayBehavior=Get-SelectedTag $toggleRadios "Show on change"
    $cfg.toggle.duration=[double]$numToggleDur.Value

    $cfg.hold.enabled=$chkHold.Checked
    $cfg.hold.vk=[int]$script:holdVk
    $cfg.hold.key=(Vk-ToName $script:holdVk)
    $cfg.hold.overlayBehavior=Get-SelectedTag $holdRadios "Always show while held"
}

function Copy-Appearance-UI-ToConfig {
    $cfg.appearance.shape=[string]$cmbShape.SelectedItem
    $cfg.appearance.size=[int]$numSize.Value
    $cfg.appearance.opacity=[int]$numOpacity.Value
    $cfg.appearance.x=[int]$numX.Value
    $cfg.appearance.y=[int]$numY.Value
    $cfg.appearance.monitor=[string]$cmbMonitor.SelectedItem
    $cfg.appearance.mutedColor=$btnMutedColor.Text
    $cfg.appearance.unmutedColor=$btnUnmutedColor.Text
    $cfg.appearance.iconColor=$btnIconColor.Text
}

function Copy-General-UI-ToConfig {
    $cfg.general.startWithWindows=$chkStartup.Checked
    $cfg.general.startMinimized=$chkMinimized.Checked
}

function Copy-UI-ToConfig {
    Copy-OBS-UI-ToConfig
    Copy-Controls-UI-ToConfig
    Copy-Appearance-UI-ToConfig
    Copy-General-UI-ToConfig
}

function Test-ControlKeyConflict {
    if ($chkToggle.Checked -and $chkHold.Checked -and [int]$script:toggleVk -eq [int]$script:holdVk) {
        [Windows.Forms.MessageBox]::Show(
            "Mute / Unmute and Hold Mode cannot use the same key.`r`n`r`nAssign different keys or disable one of the controls.",
            "Hotkey conflict",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return $false
    }
    return $true
}

function Update-Autostart {
    $startup=[Environment]::GetFolderPath("Startup")
    $lnk=Join-Path $startup "APEIRON OBS Overlay.lnk"
    if ($cfg.general.startWithWindows) {
        try {
            $shell=New-Object -ComObject WScript.Shell
            $sc=$shell.CreateShortcut($lnk)
            $sc.TargetPath="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $sc.Arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -StartupMode'
            $sc.WorkingDirectory=$PSScriptRoot
            $sc.IconLocation=$iconPath
            $sc.Save()
        } catch { throw "Could not create the Windows startup shortcut." }
    } else {
        Remove-Item $lnk -Force -ErrorAction SilentlyContinue
    }
}

function Apply-And-Save {
    if (-not (Test-ControlKeyConflict)) {
        $lblBottom.Text="Not saved — hotkey conflict"
        return $false
    }
    try {
        Finish-Placement
        Copy-UI-ToConfig
        $cfg.general.setupCompleted=$true
        Update-Autostart
        Save-Config $cfg
        Apply-Appearance
        Update-ControlEnabledState
        Reconcile-Overlay
        $lblBottom.Text="Saved"
        return $true
    } catch {
        $lblBottom.Text="Save failed"
        [Windows.Forms.MessageBox]::Show($_.Exception.Message,"Save settings") | Out-Null
        return $false
    }
}

function Refresh-InputList {
    $current=[string]$cfg.obs.inputName
    $inputs=Get-ObsInputs
    $script:refreshingInputs=$true
    try {
        $cmbInput.Items.Clear()
        foreach ($i in ($inputs | Sort-Object inputName)) { [void]$cmbInput.Items.Add([string]$i.inputName) }
        if ($current -and $cmbInput.Items.Contains($current)) { $cmbInput.SelectedItem=$current }
        else { $cmbInput.SelectedIndex=-1 }
    } finally { $script:refreshingInputs=$false }
    $script:lastInputRefresh=Get-Date
    $script:inputReady=($current -and $cmbInput.Items.Contains($current))
    if (-not $script:inputReady) {
        $script:baseMute=$null
        $script:lastMute=$null
        Hide-Overlay
        $lblStatus.Text=if ($current) { "Selected input not found. Choose an audio input." } else { "Connected — choose an audio input." }
    } else { $lblStatus.Text="Connected" }
}

function Update-ControlEnabledState {
    $txtToggleKey.Enabled=$chkToggle.Checked
    $btnSetToggle.Enabled=$chkToggle.Checked

    $txtHoldKey.Enabled=$chkHold.Checked
    $btnSetHold.Enabled=$chkHold.Checked
    foreach($r in $holdRadios){$r.Enabled=$chkHold.Checked}

        $numToggleDur.Enabled=$true
}

function Get-TargetScreen {
    if ([string]$cmbMonitor.SelectedItem -eq "Last active monitor" -and $null -ne $script:lastExternalScreen) { return $script:lastExternalScreen }
    return [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
}

function Set-PresetPosition([string]$corner) {
    Copy-Appearance-UI-ToConfig
    $s=Get-TargetScreen
    $size=[int]$numSize.Value
    $pad=30
    switch($corner) {
        "TL" { $x=$s.Left+$pad; $y=$s.Top+$pad }
        "TR" { $x=$s.Right-$size-$pad; $y=$s.Top+$pad }
        "BL" { $x=$s.Left+$pad; $y=$s.Bottom-$size-$pad }
        "BR" { $x=$s.Right-$size-$pad; $y=$s.Bottom-$size-$pad }
    }
    $numX.Value=[Math]::Min($numX.Maximum,[Math]::Max($numX.Minimum,$x))
    $numY.Value=[Math]::Min($numY.Maximum,[Math]::Max($numY.Minimum,$y))
    Copy-Appearance-UI-ToConfig
    Apply-Appearance
    Show-Preview $true
}

function Get-ObsProcess {
    $p=Get-Process -Name "obs64" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $p) { $p=Get-Process -Name "obs32" -ErrorAction SilentlyContinue | Select-Object -First 1 }
    return $p
}

function Restart-OverlayAsAdministrator {
    if (-not (Apply-And-Save)) { return $false }
    try {
        if (-not [string]::IsNullOrWhiteSpace($env:APEIRON_LAUNCHER_PATH) -and (Test-Path $env:APEIRON_LAUNCHER_PATH)) {
            Start-Process $env:APEIRON_LAUNCHER_PATH -Verb RunAs -ArgumentList @("--wait-for", [string]$env:APEIRON_LAUNCHER_PID)
        } else {
            Start-Process powershell.exe -Verb RunAs -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy","Bypass",
                "-WindowStyle","Hidden",
                "-File",('"' + $PSCommandPath + '"'),"-WaitForPid",[string]$PID
            )
        }
        $script:reallyExit=$true
        try{$tray.Visible=$false}catch{}
        $form.Close()
        return $true
    } catch {
        return $false
    }
}

function Update-ElevationStatus {
    $btnRestartAdmin.Visible=$false
    $lblElevation.Text=""
    try {
        $op=Get-ObsProcess
        if ($null -eq $op) { return }

        $obsElevated=[ApeironProcessSecurity]::IsElevated($op.Id)
        $appElevated=[ApeironProcessSecurity]::IsElevated([Diagnostics.Process]::GetCurrentProcess().Id)

        if ($obsElevated -and -not $appElevated) {
            $lblElevation.Text="OBS is running as Administrator. Different privileges can prevent reliable hotkeys while OBS has focus. Restart the overlay as Administrator, or run both applications without elevation."
            $btnRestartAdmin.Visible=$true

            if (-not $script:elevationPromptShown -and $form.Visible) {
                $script:elevationPromptShown=$true
                $ans=[Windows.Forms.MessageBox]::Show(
                    "OBS is running as Administrator, but APEIRON OBS Overlay is not.`r`n`r`nWindows can block global hotkeys specifically while the OBS window has focus.`r`n`r`nRestart the overlay as Administrator now?",
                    "OBS privilege mismatch",
                    [Windows.Forms.MessageBoxButtons]::YesNo,
                    [Windows.Forms.MessageBoxIcon]::Warning
                )
                if ($ans -eq [Windows.Forms.DialogResult]::Yes) {
                    [void](Restart-OverlayAsAdministrator)
                }
            }
        }
    } catch {}
}

function Toggle-Microphone {
    if (-not $cfg.toggle.enabled -or -not $script:connected -or -not $script:inputReady -or [string]::IsNullOrEmpty($cfg.obs.inputName)) { return }
    if ($script:holdActive) { return } # Base state is locked while Hold Mode is active.
    if (-not (Restore-PendingHold)) { return }
    try {
        $cur=Get-InputMute $cfg.obs.inputName
        $new=-not $cur
        Set-InputMute $cfg.obs.inputName $new
        $script:baseMute=$new
        $script:lastMute=$new
        Apply-ToggleOverlay $new
    } catch {
        Handle-ObsFailure $_.Exception
    }
}

function Hold-Press {
    if (-not $cfg.hold.enabled -or -not $script:connected -or -not $script:inputReady -or [string]::IsNullOrEmpty($cfg.obs.inputName)) { return }
    if ($script:holdActive) { return }
    if (-not (Restore-PendingHold)) { return }

    try {
        $cur=Get-InputMute $cfg.obs.inputName
        $script:holdBaseMute=$cur
        $script:baseMute=$cur
        $script:pendingRestore=@{host=$cfg.obs.host;port=$cfg.obs.port;inputName=$cfg.obs.inputName;muted=$cur}

        $effective=-not $cur
        Set-InputMute $cfg.obs.inputName $effective
        $script:holdActive=$true
        $script:lastMute=$effective

        Apply-HoldOverlay
    } catch {
        $script:holdActive=$false
        $script:holdBaseMute=$null
        Handle-ObsFailure $_.Exception
    }
}

function Hold-Release {
    if (-not $script:holdActive) { return }

    $restore=[bool]$script:holdBaseMute
    $restored=$false
    try {
        if ($script:connected -and $script:inputReady -and -not [string]::IsNullOrEmpty($cfg.obs.inputName)) {
            Set-InputMute $cfg.obs.inputName $restore
            $script:lastMute=$restore
            $script:pendingRestore=$null
            $restored=$true
        }
    } catch { Handle-ObsFailure $_.Exception }

    $script:baseMute=if($restored){$restore}else{$null}
    $script:holdActive=$false
    $script:holdBaseMute=$null

    # No separate "Hold ended" popup. Restore only the base overlay state.
    Restore-BaseOverlay
}

function Handle-ObsFailure($exception) {
    if ($null -ne $exception.Data["OBSCode"]) {
        $script:inputReady=$false
        $script:holdActive=$false
        $script:holdBaseMute=$null
        $script:baseMute=$null
        $script:lastMute=$null
        Hide-Overlay
        $lblStatus.Text="Selected input unavailable. Choose an audio input."
    } else {
        Disconnect-OBS
        $lblStatus.Text="OBS disconnected — waiting to reconnect."
    }
}

function Restore-PendingHold {
    $p=$script:pendingRestore
    if ($null -eq $p) { return $true }
    if ($p.host -ne $cfg.obs.host -or $p.port -ne $cfg.obs.port -or $p.inputName -ne $cfg.obs.inputName) { return $true }
    try {
        Set-InputMute $p.inputName ([bool]$p.muted)
        $script:baseMute=[bool]$p.muted
        $script:pendingRestore=$null
        Restore-BaseOverlay
        return $true
    } catch { Handle-ObsFailure $_.Exception; return $false }
}

function Sync-ControlInput {
    [ApeironGlobalInput]::ClearPresses()
    $script:toggleWasDown=Vk-IsDown ([int]$cfg.toggle.vk)
    $script:holdWasDown=Vk-IsDown ([int]$cfg.hold.vk)
}

function Process-ControlInput([bool]$toggleDown, [bool]$holdDown, [bool]$togglePressed=$false, [bool]$holdPressed=$false) {
    if (-not $cfg.toggle.enabled) { $toggleDown=$false; $togglePressed=$false }
    if (-not $cfg.hold.enabled) { $holdDown=$false; $holdPressed=$false }
    # Release -> press -> Toggle. Toggle presses during Hold are consumed.
    if (-not $holdDown -and $script:holdActive) { Hold-Release }
    if (($holdDown -and -not $script:holdWasDown) -or ($holdPressed -and -not $script:holdWasDown)) {
        Hold-Press
        if (-not $holdDown) { Hold-Release }
    }
    if ((($toggleDown -and -not $script:toggleWasDown) -or ($togglePressed -and -not $script:toggleWasDown)) -and -not $script:holdActive -and -not $holdPressed) { Toggle-Microphone }
    $script:toggleWasDown=$toggleDown
    $script:holdWasDown=$holdDown
}

function Finish-Placement {
    if (-not $script:placement) { return }
    $x=$overlay.Left; $y=$overlay.Top
    $script:placement=$false
    $overlay.SetPlacementMode($false)
    $btnPlace.Text="Place by dragging"
    $btnPlace.UseVisualStyleBackColor=$true
    $btnPlace.BackColor=$script:placeBackColor
    $btnPlace.ForeColor=$script:placeForeColor
    $btnPlace.Font=$form.Font
    $lblPlacement.Text="Position applied. Save / Apply to keep it."
    foreach ($c in $tabLook.Controls) { $c.Enabled=$true }
    $numX.Value=[Math]::Min($numX.Maximum,[Math]::Max($numX.Minimum,$x))
    $numY.Value=[Math]::Min($numY.Maximum,[Math]::Max($numY.Minimum,$y))
    Copy-Appearance-UI-ToConfig
    $script:previewActive=$false
    Update-OverlayVisibility
}

# ---------------- UI events ----------------
$btnSetToggle.Add_Click({
    $v=Capture-Key "Set Mute / Unmute key"
    if ($v -gt 0) {
        if ($chkHold.Checked -and [int]$v -eq [int]$script:holdVk) {
            [Windows.Forms.MessageBox]::Show(
                "This key is already assigned to Hold Mode.",
                "Hotkey conflict",
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        } else {
            $script:toggleVk=[int]$v
            $cfg.toggle.vk=[int]$v
            $cfg.toggle.key=Vk-ToName $script:toggleVk
            $txtToggleKey.Text=$cfg.toggle.key
            Sync-ControlInput
            $lblBottom.Text="Mute / Unmute key changed — Save to keep it"
        }
    }
})
$btnSetHold.Add_Click({
    $v=Capture-Key "Set Hold Mode key"
    if ($v -gt 0) {
        if ($chkToggle.Checked -and [int]$v -eq [int]$script:toggleVk) {
            [Windows.Forms.MessageBox]::Show(
                "This key is already assigned to Mute / Unmute.",
                "Hotkey conflict",
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        } else {
            $script:holdVk=[int]$v
            $cfg.hold.vk=[int]$v
            $cfg.hold.key=Vk-ToName $script:holdVk
            $txtHoldKey.Text=$cfg.hold.key
            Sync-ControlInput
            $lblBottom.Text="Hold Mode key changed — Save to keep it"
        }
    }
})

foreach($r in $toggleRadios){
    $r.Add_CheckedChanged({
        if ($this.Checked) {
            $cfg.toggle.overlayBehavior=[string]$this.Tag
            Update-ControlEnabledState
            Reconcile-Overlay
        }
    })
}
foreach($r in $holdRadios){
    $r.Add_CheckedChanged({
        if ($this.Checked) {
            $cfg.hold.overlayBehavior=[string]$this.Tag
            Update-ControlEnabledState
            Reconcile-Overlay
        }
    })
}
$numToggleDur.Add_ValueChanged({$cfg.toggle.duration=[double]$numToggleDur.Value})

$chkToggle.Add_CheckedChanged({
    $cfg.toggle.enabled=$chkToggle.Checked
    Sync-ControlInput
    if ($chkToggle.Checked -and $chkHold.Checked -and [int]$script:toggleVk -eq [int]$script:holdVk) {
        $chkToggle.Checked=$false
        $cfg.toggle.enabled=$false
        [Windows.Forms.MessageBox]::Show(
            "Mute / Unmute cannot be enabled because Hold Mode uses the same key.",
            "Hotkey conflict",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
    Update-ControlEnabledState
})

$chkHold.Add_CheckedChanged({
    if (-not $chkHold.Checked -and $script:holdActive) { Hold-Release }
    $cfg.hold.enabled=$chkHold.Checked
    Sync-ControlInput
    if ($chkHold.Checked -and $chkToggle.Checked -and [int]$script:holdVk -eq [int]$script:toggleVk) {
        $chkHold.Checked=$false
        $cfg.hold.enabled=$false
        [Windows.Forms.MessageBox]::Show(
            "Hold Mode cannot be enabled because Mute / Unmute uses the same key.",
            "Hotkey conflict",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
    Update-ControlEnabledState
})

Update-ControlEnabledState

foreach ($b in @($btnMutedColor,$btnUnmutedColor,$btnIconColor)) {
    $b.Add_Click({ param($sender,$e) Choose-Color $sender })
}
$btnTestMute.Add_Click({Copy-Appearance-UI-ToConfig;Show-Preview $true})
$btnTestOn.Add_Click({Copy-Appearance-UI-ToConfig;Show-Preview $false})

$btnTopLeft.Add_Click({Set-PresetPosition "TL"})
$btnTopRight.Add_Click({Set-PresetPosition "TR"})
$btnBottomLeft.Add_Click({Set-PresetPosition "BL"})
$btnBottomRight.Add_Click({Set-PresetPosition "BR"})

$btnPlace.Add_Click({
    if (-not $script:placement) {
        Copy-Appearance-UI-ToConfig
        $script:previewActive=$false
        Render-Overlay $true
        $script:placement=$true
        $btnPlace.Text="Finish placement ✓"
        $btnPlace.UseVisualStyleBackColor=$false
        $btnPlace.BackColor=[Drawing.Color]::FromArgb(125,220,165)
        $btnPlace.ForeColor=[Drawing.Color]::Black
        $btnPlace.Font=New-Object Drawing.Font($form.Font,[Drawing.FontStyle]::Bold)
        $lblPlacement.Text="Drag the overlay, then click the green Finish placement button."
        foreach ($c in $tabLook.Controls) { $c.Enabled=($c -eq $btnPlace -or $c -eq $lblPlacement) }
        $overlay.SetPlacementMode($true)
    } else {
        Finish-Placement
    }
})

$btnConnect.Add_Click({
    try {
        if ($script:holdActive) { Hold-Release }
        Copy-OBS-UI-ToConfig
        $script:passwordRequired=$false
        $lblStatus.Text="Connecting..."
        if (Connect-OBS $cfg.obs.host $cfg.obs.port $txtPass.Text) {
            Refresh-InputList
            if ($script:inputReady) { $null=Restore-PendingHold; Poll-OBS }
            $lblBottom.Text="OBS connected — Save to keep its settings"
            Update-ElevationStatus
        }
    } catch {
        Handle-ObsFailure $_.Exception
        [Windows.Forms.MessageBox]::Show($_.Exception.Message,"OBS connection",[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
})

$cmbInput.Add_SelectedIndexChanged({
    if ($script:refreshingInputs -or $null -eq $cmbInput.SelectedItem) { return }
    if ($script:holdActive) { Hold-Release }
    $cfg.obs.inputName=[string]$cmbInput.SelectedItem
    $script:lastMute=$null
    $script:baseMute=$null
    $script:inputReady=$script:connected
    Hide-Overlay
    if ($script:connected) { Poll-OBS }
    $lblBottom.Text="Audio input changed — Save to keep it"
})

$txtPass.Add_TextChanged({
    $script:sessionPassword=$txtPass.Text
    $script:passwordRequired=$false
})

$btnRestartAdmin.Add_Click({
    [void](Restart-OverlayAsAdministrator)
})

$btnOpenSettings.Add_Click({
    New-Item -ItemType Directory -Force -Path $baseDir | Out-Null
    Start-Process explorer.exe $baseDir
})

$btnReset.Add_Click({
    $ans=[Windows.Forms.MessageBox]::Show(
        "Reset all APEIRON OBS Overlay settings for this Windows user?`r`n`r`nThe application will close afterwards.",
        "Reset settings",
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($ans -eq [Windows.Forms.DialogResult]::Yes) {
        if ($script:holdActive) { Hold-Release }
        try { Remove-Item $configPath -Force -ErrorAction SilentlyContinue } catch {}
        Remove-Item ($configPath+".bak"),($configPath+".tmp") -Force -ErrorAction SilentlyContinue
        $cfg.general.startWithWindows=$false
        Update-Autostart
        $script:sessionPassword=""
        $script:reallyExit=$true
        $tray.Visible=$false
        $form.Close()
    }
})

$btnWebsite.Add_Click({Open-Url $authorWebsite})
$btnPaypal.Add_Click({Open-Url $authorPayPal})

$btnDiagnostics.Add_Click({
    $obsProc=Get-ObsProcess
    $obsAdmin="Unknown"
    if ($null -ne $obsProc) { $obsAdmin=[ApeironProcessSecurity]::IsElevated($obsProc.Id) }
    $appAdmin=[ApeironProcessSecurity]::IsElevated([Diagnostics.Process]::GetCurrentProcess().Id)
    $muteText="Unknown"
    if ($null -ne $script:lastMute) { $muteText=if([bool]$script:lastMute){"MUTED"}else{"ON"} }
    $diag=@"
APEIRON OBS Overlay $appVersion
Windows: $([Environment]::OSVersion.VersionString)
PowerShell: $($PSVersionTable.PSVersion)
OBS connection: $(if($script:connected){"Connected"}else{"Disconnected"})
OBS input: $($cfg.obs.inputName)
Global input hook: $(if($script:hookStarted){"OK"}else{"Failed / fallback"})
Current mic state: $muteText
Overlay elevated: $appAdmin
OBS elevated: $obsAdmin
Launcher: $(if([string]::IsNullOrWhiteSpace($env:APEIRON_LAUNCHER_PATH)){"PowerShell"}else{"EXE"})
"@
    [Windows.Forms.Clipboard]::SetText($diag.Trim())
    $lblBottom.Text="Diagnostics copied"
})

$btnSave.Add_Click({[void](Apply-And-Save)})
$btnHide.Add_Click({if (Apply-And-Save) { $form.Hide() }})

$mSettings.Add_Click({$form.Show();$form.WindowState="Normal";$form.Activate()})
$mTestMute.Add_Click({Show-Preview $true})
$mTestOn.Add_Click({Show-Preview $false})
$tray.Add_DoubleClick({$form.Show();$form.WindowState="Normal";$form.Activate()})
$mExit.Add_Click({
    $script:reallyExit=$true
    $form.Close()
})

$form.Add_FormClosing({
    param($sender,$e)
    if (-not $script:reallyExit) {
        $e.Cancel=$true
        if (Apply-And-Save) {
            $form.Hide()
            $tray.ShowBalloonTip(1200,"APEIRON OBS Overlay","Still running in the system tray.",[Windows.Forms.ToolTipIcon]::Info)
        }
    }
})

# ---------------- Runtime timers ----------------
$fastTimer=New-Object Windows.Forms.Timer
$fastTimer.Interval=35
$fastTimer.Add_Tick({
    Update-OverlayVisibility
    try {
        $h=[ApeironNative]::GetForegroundWindow()
        [uint32]$foregroundPid=0
        if ($h -ne [IntPtr]::Zero) {
            [void][ApeironNative]::GetWindowThreadProcessId($h,[ref]$foregroundPid)
            if ($foregroundPid -ne [Diagnostics.Process]::GetCurrentProcess().Id) { $script:lastExternalScreen=[Windows.Forms.Screen]::FromHandle($h).WorkingArea }
        }
    } catch {}

    if (-not $script:keyCaptureActive) {
        $toggleDown=$false
        $holdDown=$false
        if ($cfg.toggle.enabled) { $toggleDown=Vk-IsDown ([int]$cfg.toggle.vk) }
        if ($cfg.hold.enabled) { $holdDown=Vk-IsDown ([int]$cfg.hold.vk) }

        $togglePressed=[ApeironGlobalInput]::ConsumePress([int]$cfg.toggle.vk)
        $holdPressed=[ApeironGlobalInput]::ConsumePress([int]$cfg.hold.vk)
        Process-ControlInput $toggleDown $holdDown $togglePressed $holdPressed
    }
})
$fastTimer.Start()

$obsTimer=New-Object Windows.Forms.Timer
$obsTimer.Interval=250
function Poll-OBS {
    if (-not $script:connected) {
        if ($cfg.obs.autoConnect -and -not $script:passwordRequired -and ((Get-Date)-$script:lastReconnect).TotalSeconds -ge 3) {
            $script:lastReconnect=Get-Date
            if (Connect-OBS $cfg.obs.host ([int]$cfg.obs.port) $script:sessionPassword -Quiet) {
                try {
                    Refresh-InputList
                    if ($script:inputReady) { $null=Restore-PendingHold }
                } catch { Handle-ObsFailure $_.Exception }
                Update-ElevationStatus
            } else {
                $lblStatus.Text=if($script:passwordRequired){"Enter the OBS password and connect."}else{"Waiting for OBS..."}
            }
        }
        return
    }

    if (-not $script:inputReady) {
        if (((Get-Date)-$script:lastInputRefresh).TotalSeconds -ge 5) {
            try { Refresh-InputList } catch { Handle-ObsFailure $_.Exception }
        }
        return
    }
    if (-not $script:holdActive -and -not (Restore-PendingHold)) { return }

    try {
        $m=Get-InputMute $cfg.obs.inputName

        if ($null -eq $script:lastMute) {
            $script:lastMute=$m
            $script:baseMute=$m
            if (-not $script:holdActive) { Restore-BaseOverlay }
            return
        }

        # Hold Mode owns the effective state until release.
        if ($script:holdActive) {
            $expected=-not [bool]$script:holdBaseMute
            if ($m -ne $expected) {
                Set-InputMute $cfg.obs.inputName $expected
                $script:lastMute=$expected
            } else {
                $script:lastMute=$m
            }
            return
        }

        if ($m -ne $script:lastMute) {
            $script:lastMute=$m
            $script:baseMute=$m

            # Overlay monitoring is independent from the app's Mute/Unmute hotkey.
            # This lets users keep an OBS-native hotkey while using this app only as an overlay.

            # Skip duplicate popup after a change made by this app.
            Apply-ToggleOverlay $m
        }
    } catch {
        Handle-ObsFailure $_.Exception
    }
}
$obsTimer.Add_Tick({Poll-OBS})
$obsTimer.Start()

# ---------------- Startup ----------------
Apply-Appearance
Update-ControlEnabledState
if ($cfg.general.startWithWindows) { Update-Autostart }

if ($cfg.obs.autoConnect) { Poll-OBS }

$script:hookStarted=[ApeironGlobalInput]::Start()
Sync-ControlInput
if ($script:hookStarted) {
    $lblBottom.Text="Ready — global hotkeys active"
} else {
    $lblBottom.Text="Ready — global hook failed; fallback polling active"
}
if ($script:configNotice) { $lblBottom.Text=$script:configNotice }

if ($StartupMode -and $cfg.general.startMinimized -and $cfg.general.setupCompleted -and -not $DebugMode -and -not $script:firstRun) {
    $form.ShowInTaskbar=$false
    $form.Add_Shown({$form.Hide();$form.ShowInTaskbar=$true})
} else {
    $form.Add_Shown({
        $form.ShowInTaskbar=$true
        $form.WindowState=[Windows.Forms.FormWindowState]::Normal
        $form.Show();$form.BringToFront();$form.Activate()
    })
}

if ($script:firstRun -or -not [bool]$cfg.general.setupCompleted) {
    $form.Add_Shown({
        $tabs.SelectedTab=$tabObs
        [Windows.Forms.MessageBox]::Show(
            "First setup:`r`n`r`n1. Enable the OBS WebSocket server.`r`n2. Enter the connection details and click Connect / refresh.`r`n3. Select your microphone input.`r`n4. Open Controls and assign Mute / Unmute and Hold Mode keys.`r`n5. Save / Apply.`r`n`r`nNo OBS password, microphone name, or personal hotkeys are built into the app.",
            "APEIRON OBS Overlay — first setup",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    })
}

$form.Add_Shown({
    Update-ElevationStatus
})

try { [Windows.Forms.Application]::Run($form) }
finally {
    $fastTimer.Stop(); $obsTimer.Stop()
    try { if ($script:holdActive) { Hold-Release } } catch {}
    try { if ($script:pendingRestore -and $script:connected -and $script:inputReady) { $null=Restore-PendingHold } } catch {}
    try { [ApeironGlobalInput]::Stop() } catch {}
    try { Disconnect-OBS } catch {}
    try { $overlay.Dispose(); $tray.Visible=$false; $tray.Dispose() } catch {}
    $script:sessionPassword=""
    if ($script:ownsInstance) { $script:instanceMutex.ReleaseMutex() }
    $script:instanceMutex.Dispose()
}
        