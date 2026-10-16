#requires -Version 5.1
<#
  dsh-float-ball —— DSH 托盘悬浮球（窗口本体）

  由宿主半区（lib/index.js）以子进程方式拉起，负责：
    1. 画一个**白色圆形**悬浮窗，中间是 **DSH 图标**；
    2. 左键可拖动到任意位置（WPF 原生 DragMove，拖动结束把坐标写进 position.txt）；
    3. **单击**（几乎没拖动）→ 唤回 DSH 主窗口；
    4. 轮询 DSH 主窗口状态：被收进托盘（隐藏）→ 自己出现；主窗口回来 → 自己消失。

  为什么用 PowerShell + WPF，而不是 Electron / 自带原生 exe：
    · DSH 官方《插件开发》文档把 Electron `BrowserWindow`、托盘注册表、private Node helper
      都列为**不属于第三方契约**的内部实现，插件不应依赖它们；
    · 插件半区跑在 DSH 的 Node 宿主进程里，本来也拿不到窗口 API；
    · WPF（.NET Framework 自带）能给出带逐像素透明的**抗锯齿**圆形窗口，
      且**不需要任何编译产物**（不像 WinForms+WebView2 那样必须随包发 .exe）。
  详见 README 的「为什么是这样实现的」。

  依赖：Windows PowerShell 5.1 + .NET Framework（Windows 10/11 自带）。
        那段 `Add-Type` 原生小助手（IsIconic / ShowWindow / SetForegroundWindow）是**可选**的：
        编译不出来就自动降级（见 $script:NativeReady）。
#>

[CmdletBinding()]
param(
  # 状态目录（position.txt / float-ball.log 都放这里）
  [Parameter(Mandatory = $true)][string]$StateDir,
  # DSH 图标路径（通常是 <安装目录>\resources\icon.png）
  [string]$IconPath = '',
  # DSH 可执行文件路径（单击悬浮球时用它把 DSH 唤回前台）
  [string]$AppExe = '',
  # DSH 主进程 pid（宿主给的线索；还会自己扫描同可执行文件的进程）
  [int]$TargetPid = 0,
  # 悬浮球直径（DIP）
  [int]$Size = 72,
  # 轮询间隔（毫秒）
  [int]$PollMs = 700,
  # "最小化到任务栏"也算"收起来了"（需要原生小助手可用；不可用则只认托盘隐藏）
  [switch]$IncludeMinimized,
  # 调试用：无视 DSH 是否可见，一直显示悬浮球
  [switch]$AlwaysVisible,
  # 只跑"唤回 DSH"这一条路径（找到主窗口——含隐藏到托盘的——并显示出来）然后退出，不建窗口。
  # 用来在不点鼠标的情况下实测唤回逻辑。
  [switch]$RestoreOnly,
  # 配合 -RestoreOnly：无视 DSH 当前是否可见，强制执行一次完整唤回（自检用）
  [switch]$ForceShow
)

$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# 日志
# ─────────────────────────────────────────────────────────────────────────────
$script:LogDir = $StateDir
$script:LogFile = Join-Path $StateDir 'float-ball.log'

function Write-Log {
  param([string]$Message)
  $line = '[' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '] [window] ' + $Message
  try {
    if (-not (Test-Path -LiteralPath $script:LogDir)) {
      New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    }
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
  } catch { }
}

try {
  if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  }
  if (Test-Path -LiteralPath $script:LogFile) {
    if ((Get-Item -LiteralPath $script:LogFile).Length -gt 1048576) {
      Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue
    }
  }
} catch { }

Write-Log ('start: pid=' + $PID + ' targetPid=' + $TargetPid + ' size=' + $Size + ' pollMs=' + $PollMs +
           ' includeMinimized=' + ([bool]$IncludeMinimized) + ' alwaysVisible=' + ([bool]$AlwaysVisible) +
           ' icon=' + $IconPath + ' appExe=' + $AppExe)

# ─────────────────────────────────────────────────────────────────────────────
# 状态
# ─────────────────────────────────────────────────────────────────────────────
$script:Always = [bool]$AlwaysVisible
$script:WantMinimized = [bool]$IncludeMinimized
$script:NativeReady = $false
$script:DshPids = @()                  # 候选：可执行文件 == AppExe 的进程（Electron 主进程 + 它的子进程）
$script:SeenVisible = $false           # 至少见过一次 DSH 主窗口可见，之后才相信"不可见 = 收进托盘"
$script:MissCount = 0                  # 连续多少次找不到 DSH 进程
$script:TicksSinceScan = 0
$script:LastActivate = [DateTime]::MinValue
# 最近一次"窗口被搬回屏幕"的时间（用于缓存窗口位置查询）
$script:LastOnScreenAt = [DateTime]::MinValue
$script:PositionFile = Join-Path $StateDir 'position.txt'
$script:DragFromLeft = 0.0
$script:DragFromTop = 0.0
# 唤回后在后台观察"网页内容是否回来"的定时器（见 Start-ContentWatchdog）
$script:Watchdog = $null
$script:WatchdogTimer = $null
$script:WatchdogTicks = 0
$script:WatchdogHandle = [IntPtr]::Zero

# ─────────────────────────────────────────────────────────────────────────────
# 原生小助手（可选，编译不出来会降级）
#   IsIconic              → 识别"最小化到任务栏"
#   EnumWindows + 过滤     → **找回隐藏到托盘的主窗口句柄**（关键：句柄还在，只是 .NET 看不到）
#   ShowWindow/ActivateWindow/SetForegroundWindow → 显示、激活并置前
# ─────────────────────────────────────────────────────────────────────────────
try {
  $nativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class DshFloatNative
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT
    {
        public int length; public int flags; public int showCmd;
        public POINT minPosition; public POINT maxPosition; public RECT normalPosition;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct NOTIFYICONIDENTIFIER { public uint cbSize; public IntPtr hWnd; public uint uID; public Guid guidItem; }

    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr hdc, int x, int y);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, IntPtr dwExtraInfo);
    [DllImport("shell32.dll")] public static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER identifier, out RECT iconLocation);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    // 最小化的窗口"还原后应该是最大化"吗？
    //   WINDOWPLACEMENT.flags 里的 WPF_RESTORETOMAXIMIZED(0x0002) 表示：
    //   这个窗口最小化之前是最大化的，SW_RESTORE 应该还原成最大化。
    //   不读这个标志就会出现"最大化 → 最小化 → 点球 → 变成普通尺寸"的回归。
    public static bool RestoresToMaximized(IntPtr hWnd)
    {
        WINDOWPLACEMENT p = new WINDOWPLACEMENT();
        p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        if (!GetWindowPlacement(hWnd, ref p)) return false;
        return (p.flags & 0x0002) != 0;
    }
    public static string ClassOf(IntPtr hWnd)
    {
        StringBuilder sb = new StringBuilder(256);
        GetClassName(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    // 当前显示状态：1=SW_SHOWNORMAL 2=SW_SHOWMINIMIZED 3=SW_SHOWMAXIMIZED（0=隐藏）；-1=读不到
    public static int ShowCmdOf(IntPtr hWnd)
    {
        WINDOWPLACEMENT p = new WINDOWPLACEMENT();
        p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        if (!GetWindowPlacement(hWnd, ref p)) return -1;
        return p.showCmd;
    }

    // 让 Chromium 按"当前客户区尺寸"重新排版。
    // 为什么需要：外部 ShowWindow 不会走 Electron 的 NativeWindow::Show()，WebContents 可能既没被告知
    // 可见性变化、也没拿到新的尺寸，合成器于是还按旧尺寸出图 —— 表现就是"只显示左上角一部分"。
    // 发一条 WM_SIZE（SIZE_RESTORED + 当前客户区大小）让它按现在的尺寸重新布局，再强制重画一帧。
    // 只发消息、不改窗口几何/状态，最大化与普通都不受影响。
    public static void NudgeRelayout(IntPtr hWnd)
    {
        RECT r;
        if (!GetClientRect(hWnd, out r)) return;
        int w = r.Right - r.Left;
        int hgt = r.Bottom - r.Top;
        if (w <= 0 || hgt <= 0) return;
        IntPtr lParam = (IntPtr)((hgt << 16) | (w & 0xFFFF));
        SendMessage(hWnd, 0x0005, IntPtr.Zero, lParam);                             // WM_SIZE
        RedrawWindow(hWnd, IntPtr.Zero, IntPtr.Zero, 0x0001 | 0x0080 | 0x0100);     // INVALIDATE|ALLCHILDREN|UPDATENOW
    }

    // 窗口是否"被移出屏幕"。
    //   DSH 关闭到托盘后，若宿主已被打过补丁（hideMainWindow 改成移出屏幕），
    //   那么窗口仍然 WS_VISIBLE（IsWindowVisible=True），只是坐标在虚拟屏幕之外。
    //   悬浮球必须把这种情况同样视为"收起来了"，否则球永远不会出现。
    public static bool IsOffscreen(IntPtr hWnd)
    {
        RECT r;
        if (!GetWindowRect(hWnd, out r)) return false;
        int vx = GetSystemMetrics(76);   // SM_XVIRTUALSCREEN
        int vy = GetSystemMetrics(77);   // SM_YVIRTUALSCREEN
        int vw = GetSystemMetrics(78);   // SM_CXVIRTUALSCREEN
        int vh = GetSystemMetrics(79);   // SM_CYVIRTUALSCREEN
        if (vw <= 0 || vh <= 0) return false;
        int vright = vx + vw, vbottom = vy + vh;
        bool intersects = r.Right > vx && r.Bottom > vy && r.Left < vright && r.Top < vbottom;
        if (!intersects) return true;
        // 防御：DSH 的移出坐标是 -32000
        if (r.Left < -20000 || r.Top < -20000) return true;
        return false;
    }

    // 把被移出屏幕的窗口搬回屏幕内（保留尺寸，居中放在主屏工作区）
    public static bool BringOnScreen(IntPtr hWnd)
    {
        RECT r;
        if (!GetWindowRect(hWnd, out r)) return false;
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) return false;
        int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77);
        int vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
        if (vw <= 0 || vh <= 0) return false;
        int x = vx + (vw - w) / 2, y = vy + (vh - h) / 2;
        if (x < vx) x = vx;
        if (y < vy) y = vy;
        // SWP_NOZORDER(0x0004) | SWP_NOACTIVATE(0x0010)
        return SetWindowPos(hWnd, IntPtr.Zero, x, y, w, h, 0x0004 | 0x0010);
    }

    // Electron 的托盘图标宿主窗口（收系统托盘回调消息的那个隐藏窗口）
    public static IntPtr[] FindTrayHosts(uint[] pids)
    {
        List<IntPtr> found = new List<IntPtr>();
        HashSet<uint> set = new HashSet<uint>(pids);
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (!set.Contains(pid)) return true;
            if (ClassOf(h) == "Electron_NotifyIconHostWindow") found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    // 系统托盘里某个图标在屏幕上的矩形（物理像素；需要本进程 DPI 感知，否则坐标会对不上）
    public static bool IconRect(IntPtr host, uint id, out RECT rect)
    {
        NOTIFYICONIDENTIFIER n = new NOTIFYICONIDENTIFIER();
        n.cbSize = (uint)Marshal.SizeOf(typeof(NOTIFYICONIDENTIFIER));
        n.hWnd = host;
        n.uID = id;
        n.guidItem = Guid.Empty;
        int hr = Shell_NotifyIconGetRect(ref n, out rect);
        return hr == 0 && rect.Right > rect.Left && rect.Bottom > rect.Top;
    }

    // 让系统走一遍"还原窗口"的路径（等价用户点任务栏按钮时系统做的事；SendMessage 是同步的）。
    // 实测：只做 ShowWindow(SW_SHOW) 时 Chromium 要 ~24s 才重建网页内容子窗口；
    //       补一记 WM_SYSCOMMAND(SC_RESTORE) 后 ~2.7s 就能重建。
    // 让系统走一遍"最大化"路径（WM_SYSCOMMAND / SC_MAXIMIZE）
    public static void SysMaximize(IntPtr hWnd)
    {
        SendMessage(hWnd, 0x0112, (IntPtr)0xF030, IntPtr.Zero);   // WM_SYSCOMMAND, SC_MAXIMIZE
    }
    public static void SysRestore(IntPtr hWnd)
    {
        SendMessage(hWnd, 0x0112, (IntPtr)0xF120, IntPtr.Zero);   // WM_SYSCOMMAND, SC_RESTORE
    }
    // 让窗口"被激活"：外部 ShowWindow 之后补一记 WM_ACTIVATE(WA_ACTIVE) + WM_NCACTIVATE，
    // 相当于系统在用户激活窗口时会做的事。实测能让唤醒更稳（配合 SetForegroundWindow）。
    public static void ActivateWindow(IntPtr hWnd)
    {
        SendMessage(hWnd, 0x0006, (IntPtr)1, IntPtr.Zero);    // WM_ACTIVATE, WA_ACTIVE
        SendMessage(hWnd, 0x0086, (IntPtr)1, IntPtr.Zero);    // WM_NCACTIVATE, TRUE
    }

    // 窗口里还有没有 Chromium 的网页内容子窗口？
    // **应用自己 hide() 之后这个子窗口会被销毁** —— 此时窗口只剩一帧旧画面、输入没有任何接收者。
    // 注意：外部 ShowWindow 之后它会被 Chromium 自己重建（实测 3~6s），所以"没有"只代表"还没回来"。
    public static bool HasRenderWidget(IntPtr hWnd)
    {
        bool found = false;
        EnumChildWindows(hWnd, delegate(IntPtr h, IntPtr l)
        {
            if (ClassOf(h).StartsWith("Chrome_RenderWidgetHost", StringComparison.Ordinal)) { found = true; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // 给窗口内容拍一张"指纹"（尺寸 + 稀疏像素位），用来判断渲染器是不是真的在出帧。
    // 只求快速、不求精确：同一帧稳定，不同帧几乎必然不同。失败返回 0（表示"拍不到"）。
    public static ulong FrameSample(IntPtr hWnd)
    {
        try
        {
            IntPtr hdc = GetDC(hWnd);
            if (hdc == IntPtr.Zero) return 0;
            try
            {
                RECT r;
                if (!GetClientRect(hWnd, out r)) return 0;
                int w = r.Right - r.Left, hh = r.Bottom - r.Top;
                if (w <= 0 || hh <= 0) return 0;
                if (w > 400) w = 400;
                if (hh > 300) hh = 300;
                ulong acc = 1469598103934665603UL;
                for (int y = 7; y < hh; y += 53)
                {
                    for (int x = 11; x < w; x += 59)
                    {
                        uint c = (uint)GetPixel(hdc, x, y);
                        if (c == 0xFFFFFFFFu) continue;   // CLR_INVALID = 读失败，跳过
                        acc = (acc ^ (c & 0x00FFFFFFu)) * 1099511628211UL;
                    }
                }
                return acc;
            }
            finally { ReleaseDC(hWnd, hdc); }
        }
        catch { return 0; }
    }

    // DSH 主窗口（Electron）候选：顶层、无 owner、Chrome_WidgetWin*、非工具窗、尺寸像主窗口。
    // **可见与否都找** —— 收进托盘的窗口只是被 ShowWindow(SW_HIDE) 藏起来了，句柄仍然有效，
    // 而 Process.MainWindowHandle 只认可见窗口（隐藏时返回 0），所以必须自己枚举。
    public static IntPtr[] FindMainWindows(uint[] pids)
    {
        List<IntPtr> strict = new List<IntPtr>();
        List<IntPtr> loose = new List<IntPtr>();
        HashSet<uint> set = new HashSet<uint>(pids);
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (!set.Contains(pid)) return true;
            if (GetWindow(h, 4) != IntPtr.Zero) return true;                  // GW_OWNER != 0 → 弹出/子窗口
            string cls = ClassOf(h);
            if (!cls.StartsWith("Chrome_WidgetWin", StringComparison.Ordinal)) return true;
            if ((GetWindowLong(h, -20) & 0x00000080) != 0) return true;       // WS_EX_TOOLWINDOW
            // ⚠️ 最小化时 GetWindowRect 给的是"图标矩形"（约 160×28、还在 -32000），
            //    用它做尺寸过滤会把最小化的主窗口直接漏掉 —— 尺寸一律以 GetWindowPlacement().normalPosition 为准。
            if (!IsIconic(h))
            {
                int w = 0;
                int hgt = 0;
                WINDOWPLACEMENT p = new WINDOWPLACEMENT();
                p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
                if (GetWindowPlacement(h, ref p))
                {
                    w = p.normalPosition.Right - p.normalPosition.Left;
                    hgt = p.normalPosition.Bottom - p.normalPosition.Top;
                }
                if (w <= 0 || hgt <= 0)
                {
                    RECT r;
                    GetWindowRect(h, out r);
                    w = r.Right - r.Left;
                    hgt = r.Bottom - r.Top;
                }
                if (w < 200 || hgt < 150) return true;
            }
            if (cls == "Chrome_WidgetWin_1") { strict.Add(h); } else { loose.Add(h); }
            return true;
        }, IntPtr.Zero);
        if (strict.Count > 0) return strict.ToArray();
        return loose.ToArray();
    }
}
'@
  Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop
  $script:NativeReady = $true
  # 让本进程 DPI 感知：否则 Windows 会把坐标按缩放虚拟化，
  # 而 Shell_NotifyIconGetRect / 屏幕物理坐标是另一套，点托盘会点偏（实测踩过）。
  # 顺带让悬浮球按真实 DPI 渲染，边缘更清楚。
  try { [void][DshFloatNative]::SetProcessDPIAware() } catch { }
  Write-Log 'native helper ready (DPI aware; IsIconic / EnumWindows / ShowWindow / tray-icon rect)'
} catch {
  $script:NativeReady = $false
  Write-Log ('native helper unavailable, degraded mode: ' + $_.Exception.Message)
}

# ─────────────────────────────────────────────────────────────────────────────
# 找出 DSH 的候选进程
#   Electron 桌面端会有多个同路径进程（主进程 / GPU / 渲染 / utility），
#   但**只有主进程拥有可见的顶层窗口**（MainWindowHandle != 0），所以"任一候选有句柄"就是判据。
#   窗口被收进托盘后句柄读不到了，所以还要靠"曾经见过一次可见窗口"来锁定这组 pid。
# ─────────────────────────────────────────────────────────────────────────────
function Update-DshCandidates {
  $list = New-Object System.Collections.ArrayList
  if ($TargetPid -gt 0) { [void]$list.Add($TargetPid) }
  if (-not [string]::IsNullOrWhiteSpace($AppExe)) {
    try {
      foreach ($proc in [System.Diagnostics.Process]::GetProcesses()) {
        try {
          if ($proc.Path -eq $AppExe) {
            if (-not $list.Contains($proc.Id)) { [void]$list.Add($proc.Id) }
          }
        } catch { }
      }
    } catch { }
  }
  $script:DshPids = @($list.ToArray())
  Write-Log ('candidates: ' + ($script:DshPids -join ','))
}

# 返回 @{ Alive = <bool>; Visible = <bool>; Minimized = <bool>; Handle = <IntPtr> }
function Get-DshState {
  $alive = $false
  $visible = $false
  $minimized = $false
  $handle = [IntPtr]::Zero

  foreach ($dshPid in $script:DshPids) {
    try {
      $proc = [System.Diagnostics.Process]::GetProcessById($dshPid)
      if ($proc.HasExited) { continue }
      $alive = $true
      $proc.Refresh()
      $h = $proc.MainWindowHandle
      if ($h -ne [IntPtr]::Zero) {
        $visible = $true
        $handle = $h
        if ($script:NativeReady) {
          try {
            if ([DshFloatNative]::IsIconic($h)) { $minimized = $true }
          } catch { }
        }
      }
    } catch { }
  }

  # 被移出屏幕（宿主打过补丁时"关闭到托盘"就是这样）也算"收起来了"。
  # 每次查询窗口坐标很便宜，但轮询很频繁，所以刚唤醒过就跳过，避免把它误判成还在屏幕外。
  $offscreen = $false
  if ($script:NativeReady -and $visible -and $handle -ne [IntPtr]::Zero) {
    $cacheOk = (((Get-Date) - $script:LastOnScreenAt).TotalMilliseconds -lt 400)
    if (-not $cacheOk) {
      try { $offscreen = [DshFloatNative]::IsOffscreen($handle) } catch { $offscreen = $false }
    }
  }

  if ($script:DshPids.Length -eq 0) { $alive = $true }   # 没有任何线索时不判死
  return @{ Alive = $alive; Visible = $visible; Minimized = $minimized; Handle = $handle; Offscreen = $offscreen }
}

# ─────────────────────────────────────────────────────────────────────────────
# 位置持久化
# ─────────────────────────────────────────────────────────────────────────────
function Save-Position {
  try {
    $text = ([int][Math]::Round($script:Window.Left)).ToString() + ',' +
            ([int][Math]::Round($script:Window.Top)).ToString()
    Set-Content -LiteralPath $script:PositionFile -Value $text -Encoding ASCII
  } catch {
    Write-Log ('save position failed: ' + $_.Exception.Message)
  }
}

function Restore-Position {
  # WPF 的 Left/Top 与 SystemParameters 都是 DIP，单位一致，不需要 DPI 换算
  $vsLeft = [double][System.Windows.SystemParameters]::VirtualScreenLeft
  $vsTop = [double][System.Windows.SystemParameters]::VirtualScreenTop
  $vsWidth = [double][System.Windows.SystemParameters]::VirtualScreenWidth
  $vsHeight = [double][System.Windows.SystemParameters]::VirtualScreenHeight
  $size = [double]$Size

  $left = [double]::NaN
  $top = [double]::NaN
  try {
    if (Test-Path -LiteralPath $script:PositionFile) {
      $raw = Get-Content -LiteralPath $script:PositionFile -Raw
      if ($null -ne $raw) {
        $parts = $raw.Trim().Split(',')
        if ($parts.Length -ge 2) {
          $left = [double]::Parse($parts[0].Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
          $top = [double]::Parse($parts[1].Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
        }
      }
    }
  } catch {
    $left = [double]::NaN
    $top = [double]::NaN
  }

  if ([double]::IsNaN($left) -or [double]::IsNaN($top)) {
    # 首次出现：屏幕右侧、偏下
    $left = $vsLeft + $vsWidth - $size - 28.0
    $top = $vsTop + ($vsHeight * 0.62)
  }

  $maxLeft = $vsLeft + $vsWidth - $size
  $maxTop = $vsTop + $vsHeight - $size
  if ($left -lt $vsLeft) { $left = $vsLeft }
  if ($top -lt $vsTop) { $top = $vsTop }
  if ($left -gt $maxLeft) { $left = $maxLeft }
  if ($top -gt $maxTop) { $top = $maxTop }

  $script:Window.Left = $left
  $script:Window.Top = $top
  Write-Log ('position: ' + $left + ',' + $top)
}

# ─────────────────────────────────────────────────────────────────────────────
# 唤回 DSH
# ─────────────────────────────────────────────────────────────────────────────
# 找到 DSH 主窗口并把它显示出来 —— 最小化 与 隐藏到托盘 走同一条路径。
#   关键点：收进托盘的窗口只是被 ShowWindow(SW_HIDE) 藏起来，**句柄依然存在**；
#   而 .NET 的 Process.MainWindowHandle 只认可见的顶层窗口（隐藏时返回 0），
#   所以必须自己 EnumWindows 按 (pid + Chrome_WidgetWin_1 + 无 owner + 尺寸像主窗口) 找。
function Restore-DshWindow {
  if (-not $script:NativeReady) { return $false }
  if ($script:DshPids.Length -eq 0) { return $false }

  $handles = @()
  try {
    [uint32[]]$pids = @($script:DshPids)
    $handles = @([DshFloatNative]::FindMainWindows($pids))
  } catch {
    Write-Log ('restore: enumerate failed: ' + $_.Exception.Message)
    return $false
  }
  if ($handles.Length -eq 0) {
    Write-Log 'restore: no DSH main window handle found'
    return $false
  }

  $visibleList = @()
  foreach ($h in $handles) { $visibleList += [string][DshFloatNative]::IsWindowVisible($h) }
  Write-Log ('restore: handles=' + (($handles | ForEach-Object { $_.ToString() }) -join ',') +
             ' visibleBefore=' + ($visibleList -join ','))

  $restored = $false
  foreach ($h in $handles) {
    try {
      $visible = [DshFloatNative]::IsWindowVisible($h)
      $iconic = [DshFloatNative]::IsIconic($h)
      $zoomed = [DshFloatNative]::IsZoomed($h)
      $showCmd = [DshFloatNative]::ShowCmdOf($h)
      $frozenBefore = -not [DshFloatNative]::HasRenderWidget($h)
      Write-Log ('restore: hwnd=' + $h + ' visible=' + $visible + ' iconic=' + $iconic +
                 ' zoomed=' + $zoomed + ' showCmd=' + $showCmd + ' contentAlive=' + (-not $frozenBefore))

      # 按窗口**原来的状态**选择显示方式 —— 这一步是"显示不全"的关键：
      #   · 之前一律用 SW_RESTORE，会把"隐藏前已最大化"的窗口降级成普通尺寸，
      #     而渲染器还按最大化尺寸出图 ⇒ 只能看到左上角一块。
      #   · 最小化 → SW_RESTORE；最大化 → SW_SHOWMAXIMIZED；其余 → SW_SHOW（按原样显示，不改状态）。
      # 最小化的窗口：SW_RESTORE 会把它还原成"最小化之前的普通尺寸"，
      # 即使它最小化之前是最大化的（那样就丢了最大化状态）。
      # 所以先按 WPF_RESTORETOMAXIMIZED 标志判断，必要时再补 SW_MAXIMIZE。
      $restoreToMax = $false
      if ($iconic -or $showCmd -eq 2) {
        $restoreToMax = [DshFloatNative]::RestoresToMaximized($h)
        [DshFloatNative]::ShowWindow($h, 9) | Out-Null              # SW_RESTORE
        if ($restoreToMax) {
          Start-Sleep -Milliseconds 120
          [DshFloatNative]::ShowWindow($h, 3) | Out-Null            # SW_MAXIMIZE
        }
      } elseif ($zoomed -or $showCmd -eq 3) {
        [DshFloatNative]::ShowWindow($h, 3) | Out-Null              # SW_SHOWMAXIMIZED
      } else {
        [DshFloatNative]::ShowWindow($h, 5) | Out-Null              # SW_SHOW
      }

      if (-not [DshFloatNative]::IsWindowVisible($h)) {
        Start-Sleep -Milliseconds 150
        [DshFloatNative]::ShowWindow($h, 5) | Out-Null              # SW_SHOW
        if (-not [DshFloatNative]::IsWindowVisible($h)) { [DshFloatNative]::ShowWindow($h, 9) | Out-Null }
      }

      if ([DshFloatNative]::IsWindowVisible($h)) {
        $restored = $true
        # 若是"被移出屏幕"的窗口：先搬回屏幕内。
        # 这一步让 Electron 收到 show 事件（宿主补丁会据此恢复任务栏图标），
        # 而且 WebContents 从未被销毁，所以恢复后**立刻可用**、没有重建等待。
        if ([DshFloatNative]::IsOffscreen($h)) {
          $moved = $false
          try { $moved = [DshFloatNative]::BringOnScreen($h) } catch { $moved = $false }
          $script:LastOnScreenAt = Get-Date
          Write-Log ('restore: window was offscreen; moved back on screen=' + $moved)
          Start-Sleep -Milliseconds 200
        }
        # 补一记 WM_ACTIVATE(WA_ACTIVE)：让窗口的激活状态也跟着回来（更接近"用户点了托盘"）。
        # 只用 SetForegroundWindow 时 Electron 可能不做激活处理，补这条更稳。
        [DshFloatNative]::ActivateWindow($h)
        # 再走一遍系统的"还原/最大化"路径。
        # ⚠️ 诚实说明（v0.1.5 实测）：这条路**不可靠** —— 5 轮对照里只有 1 轮及时恢复，
        #    4 轮 15s 内内容都没回来（唯一成功那轮 24s）。它有时能把重建从 ~24s 缩短到 ~3s，
        #    但那更像偶发，不是稳定修复。保留它是因为"有比没有好"，不要指望它。
        #    真正能恢复 WebContents 的只有 DSH 自己调 window.show()（= 用户点它自己的托盘图标），
        #    外部 ShowWindow / 窗口消息 / 再启动 exe / UIA 调任务栏与托盘按钮，实测全都无法可靠唤醒。
        # 注意 SC_RESTORE 会把最大化的窗口还原成普通尺寸，所以最大化时改发 SC_MAXIMIZE。
        if ($zoomed -or $restoreToMax -or [DshFloatNative]::IsZoomed($h)) {
          [DshFloatNative]::SysMaximize($h)
        } else {
          [DshFloatNative]::SysRestore($h)
        }
        # 让 Chromium 按当前客户区尺寸重新排版（修"只显示左上角一部分"）
        [DshFloatNative]::NudgeRelayout($h)
        [DshFloatNative]::SetForegroundWindow($h) | Out-Null
      }
      Write-Log ('restore: after hwnd=' + $h + ' visible=' + [DshFloatNative]::IsWindowVisible($h) +
                 ' iconic=' + [DshFloatNative]::IsIconic($h) + ' zoomed=' + [DshFloatNative]::IsZoomed($h) +
                 ' contentAlive=' + [DshFloatNative]::HasRenderWidget($h))
    } catch {
      Write-Log ('restore: failed: ' + $_.Exception.Message)
    }
  }
  return $restored
}

# 等窗口里的网页内容回来 **并且开始出帧**。
#   为什么需要：DSH 关闭到托盘走的是 Electron 的 win.hide()，它会把 Chromium 的
#   网页内容子窗口（Chrome_RenderWidgetHostHWND）**销毁**；窗口只剩最后一帧旧画面，
#   此时窗口"看得见但点不动"。外部 ShowWindow 之后 Chromium 会自己重建那个子窗口，
#   实测要 3~6s（子窗口回来）再 ~0.5s 渲染器才开始出帧。
#   老版本只等 0.3s 就写 "STILL FROZEN"，把"正在恢复"误报成"恢复不了"。
#   判定：子窗口存在 **且** 像素帧在变（渲染器真的在画）。
function Test-DshContentAlive {
  param([IntPtr]$Handle, [int]$SampleMs = 350)
  if (-not [DshFloatNative]::HasRenderWidget($Handle)) { return $false }
  $a = [DshFloatNative]::FrameSample($Handle)
  Start-Sleep -Milliseconds $SampleMs
  $b = [DshFloatNative]::FrameSample($Handle)
  return ($a -ne 0 -and $b -ne 0 -and $a -ne $b)
}

# 同步版：给 -RestoreOnly 自检用（阻塞没关系）
function Wait-DshContentAlive {
  param([IntPtr]$Handle, [int]$TimeoutMs = 10000, [int]$StepMs = 250)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $tick = 0
  while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
    Start-Sleep -Milliseconds $StepMs
    $tick += 1
    try {
      if (Test-DshContentAlive -Handle $Handle) {
        Write-Log ('content: web contents back and repainting after ' + $sw.ElapsedMilliseconds + 'ms')
        return $true
      }
      # 期间每 ~1s 补一次 SW_SHOW：窗口若被应用又藏起来，内容永远不会重建。
      if (($tick % 4) -eq 0 -and -not [DshFloatNative]::IsWindowVisible($Handle)) {
        [DshFloatNative]::ShowWindow($Handle, 5) | Out-Null
      }
    } catch { }
  }
  Write-Log ('content: web contents did NOT come back within ' + $TimeoutMs + 'ms')
  return $false
}

# 窗口是不是被"应用自己 hide()"了 —— 判据：Chromium 的网页内容子窗口已经不存在。
# 注意：这只说明"内容还没回来"，**不代表恢复不了** —— 显示窗口之后它会自己重建，
# 所以单击唤回以后不要立刻拿它下结论（v0.1.3 就是在这里误报的）。
function Test-DshFrozen {
  if (-not $script:NativeReady) { return $false }
  $handles = @()
  try {
    [uint32[]]$pids = @($script:DshPids)
    $handles = @([DshFloatNative]::FindMainWindows($pids))
  } catch { return $false }
  foreach ($h in $handles) {
    try { if ([DshFloatNative]::IsWindowVisible($h) -and -not [DshFloatNative]::HasRenderWidget($h)) { return $true } } catch { }
  }
  return $false
}

# 直接去点 DSH 自己的托盘图标（等于用户手动点托盘把窗口唤回来）。
# 用 Shell_NotifyIconGetRect 取图标矩形（文档化 API），再合成一次真实鼠标点击。
function Invoke-TrayIconClick {
  if (-not $script:NativeReady) { return $false }
  $hosts = @()
  try {
    [uint32[]]$pids = @($script:DshPids)
    $hosts = @([DshFloatNative]::FindTrayHosts($pids))
  } catch { }
  if ($hosts.Length -eq 0) { Write-Log 'tray: no NotifyIconHostWindow found'; return $false }

  $saved = New-Object DshFloatNative+POINT
  [void][DshFloatNative]::GetCursorPos([ref]$saved)

  foreach ($th in $hosts) {
    for ($id = 0; $id -le 15; $id++) {
      $r = New-Object DshFloatNative+RECT
      $ok = $false
      try { $ok = [DshFloatNative]::IconRect($th, [uint32]$id, [ref]$r) } catch { $ok = $false }
      if (-not $ok) { continue }
      $cx = [int](($r.Left + $r.Right) / 2)
      $cy = [int](($r.Top + $r.Bottom) / 2)
      Write-Log ('tray: clicking icon id=' + $id + ' rect=' + $r.Left + ',' + $r.Top + ',' + $r.Right + ',' + $r.Bottom + ' centre=' + $cx + ',' + $cy)
      [void][DshFloatNative]::SetCursorPos($cx, $cy)
      Start-Sleep -Milliseconds 160
      [DshFloatNative]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 90
      [DshFloatNative]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 400
      [void][DshFloatNative]::SetCursorPos($saved.X, $saved.Y)
      # 判据用"内容是否活过来"而不是"窗口可不可见" —— 窗口这时本来就被我们显示出来了，
      # 只有网页内容子窗口回来了才算真的可用。
      for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Milliseconds 250
        if (-not (Test-DshFrozen)) { Write-Log 'tray: window content is live again'; return $true }
      }
    }
  }
  Write-Log 'tray: clicking the tray icon did not bring the window back'
  return $false
}

function Invoke-OpenDsh {
  # 连点保护：1.2s 内只响应一次
  if (((Get-Date) - $script:LastActivate).TotalMilliseconds -lt 1200) { return }
  $script:LastActivate = Get-Date

  Write-Log 'activate: bring DSH back'

  # ① 找到主窗口并显示出来。Restore-DshWindow 里已经包含"等网页内容回来"（Wait-DshContentAlive）：
  #    · 最小化到任务栏 → ShowWindow(SW_RESTORE)，窗口本来就能用；
  #    · 关闭到托盘 → 显示后 Chromium 会自己重建网页内容子窗口，实测 3~5s，等它回来即可。
  $restored = Restore-DshWindow
  if ($restored) {
    Write-Log 'activate: window shown'
  } else {
    # ② 兜底（句柄没找到 / ShowWindow 没生效）：再启动一次 DSH 可执行文件。
    #    实测它**不会**把已隐藏的窗口显示回来（second-instance 的 focusPrimaryWindow 在本机不执行），
    #    所以只当最后一道保险。
    if (-not [string]::IsNullOrWhiteSpace($AppExe) -and (Test-Path -LiteralPath $AppExe)) {
      try {
        Start-Process -FilePath $AppExe | Out-Null
        Write-Log 'activate: fallback launched DSH executable (single-instance handoff)'
      } catch {
        Write-Log ('activate: launch failed: ' + $_.Exception.Message)
      }
    } else {
      Write-Log 'activate: app executable unknown, cannot wake DSH'
    }
    Start-Sleep -Milliseconds 300
  }

  # ③ 补刀：AppActivate（把 DSH 提到前台，同一 pid 的窗口）
  if ($TargetPid -gt 0) {
    try {
      Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
      [Microsoft.VisualBasic.Interaction]::AppActivate($TargetPid) | Out-Null
    } catch { }
  }

  # ④ 收尾：DSH 关闭到托盘时网页内容是被应用自己销毁的，窗口显示出来后 Chromium 会用几秒把它重建。
  #    这一段只在**后台**轮询（不阻塞球的 UI 线程），恢复结果写进日志，方便事后核对。
  if (Test-DshFrozen) {
    Write-Log 'activate: window is shown; web content is still rebuilding (waiting in the background)'
    Start-ContentWatchdog
  } else {
    Write-Log 'activate: window content is live'
  }

  Update-Visibility
}

# 后台观察网页内容有没有回来 + 渲染器有没有开始出帧（一次性，最多 ~12s）。
# 用 DispatcherTimer 而不是 Start-Sleep / while：球的 UI 线程不能停，否则球会卡住不响应。
function Start-ContentWatchdog {
  if ($script:Watchdog) {
    try { $script:Watchdog.Stop() } catch { }
    $script:Watchdog = $null
  }
  $script:WatchdogTicks = 0
  $script:WatchdogHandle = [IntPtr]::Zero
  $script:WatchdogTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:WatchdogTimer.Interval = [TimeSpan]::FromMilliseconds(500)
  $script:WatchdogTimer.Add_Tick({
      $script:WatchdogTicks = $script:WatchdogTicks + 1
      $done = $false
      try {
        if ($script:WatchdogHandle -eq [IntPtr]::Zero) {
          [uint32[]]$pids = @($script:DshPids)
          $found = @([DshFloatNative]::FindMainWindows($pids))
          if ($found.Length -gt 0) { $script:WatchdogHandle = $found[0] }
        }
        $h = $script:WatchdogHandle
        if ($h -ne [IntPtr]::Zero -and (Test-DshContentAlive -Handle $h -SampleMs 300)) {
          Write-Log ('content: web contents back and repainting (~' + ($script:WatchdogTicks * 500) + 'ms after the click)')
          $done = $true
        }
      } catch { }
      if ($done -or $script:WatchdogTicks -ge 48) {
        if (-not $done) {
          Write-Log ('content: window shown, but its web content did not repaint within ~24s' +
                     ' (DSH may need its tray icon; nothing was killed)')
        }
        try { $script:WatchdogTimer.Stop() } catch { }
        $script:WatchdogTimer = $null
      }
    })
  $script:Watchdog = $script:WatchdogTimer
  $script:WatchdogTimer.Start()
}

# ─────────────────────────────────────────────────────────────────────────────
# 显示 / 隐藏
# ─────────────────────────────────────────────────────────────────────────────
function Update-Visibility {
  $script:TicksSinceScan = $script:TicksSinceScan + 1
  $state = Get-DshState

  if (-not $state.Alive) {
    if (-not $script:SeenVisible) {
      # 还没见过主窗口，候选表可能不全 → 重扫一次，别急着收摊
      Update-DshCandidates
      $script:TicksSinceScan = 0
      return
    }
    $script:MissCount = $script:MissCount + 1
    # 连续 8 次（约 6s）都找不到 DSH 主进程 → 自己收摊，避免留下孤儿进程
    if ($script:MissCount -gt 8) {
      Write-Log 'DSH main process is gone, shutting down floating ball'
      try { $script:App.Shutdown() } catch { }
    }
    return
  }
  $script:MissCount = 0

  if ($state.Visible) {
    $script:SeenVisible = $true
    $script:TicksSinceScan = 0
  } elseif ((-not $script:SeenVisible) -and ($script:TicksSinceScan -ge 10)) {
    Update-DshCandidates
    $script:TicksSinceScan = 0
  }

  $want = $false
  if ($script:Always) {
    $want = $true
  } elseif ($script:SeenVisible -and (-not $state.Visible)) {
    # 见过主窗口之后它又不可见了 = 被收进托盘 → 出球
    $want = $true
  } elseif ($state.Offscreen) {
    # 或者被移出屏幕（宿主打过补丁时"关闭到托盘"就是这个状态：窗口仍 WS_VISIBLE，但坐标在屏幕外）
    $want = $true
  } elseif ($script:WantMinimized -and $state.Minimized) {
    # 或者只是最小化到任务栏（可选；需要原生小助手）
    $want = $true
  }

  try {
    if ($want) {
      if ($script:Window.Visibility -ne [System.Windows.Visibility]::Visible) {
        Restore-Position
        $script:Window.Visibility = [System.Windows.Visibility]::Visible
        Write-Log 'show floating ball'
      }
    } else {
      if ($script:Window.Visibility -ne [System.Windows.Visibility]::Hidden) {
        $script:Window.Visibility = [System.Windows.Visibility]::Hidden
        Write-Log 'hide floating ball'
      }
    }
  } catch {
    Write-Log ('visibility error: ' + $_.Exception.Message)
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# -RestoreOnly：只跑唤回路径然后退出（实测用，不建任何窗口）
# ─────────────────────────────────────────────────────────────────────────────
if ($RestoreOnly) {
  Update-DshCandidates
  $ok = $false
  if (-not $ForceShow) {
    # 默认：只在 DSH 确实不可见时才动手（和单击悬浮球的判断一致，自检不会打扰正常使用）
    $state = Get-DshState
    if (-not $state.Alive -or ($state.Visible -and -not $state.Minimized -and -not $state.Offscreen)) {
      Write-Log ('restore-only skipped: DSH already visible (alive=' + $state.Alive + ' visible=' + $state.Visible + ' minimized=' + $state.Minimized + ' offscreen=' + $state.Offscreen + ')')
      exit 0
    }
  }
  $ok = Restore-DshWindow
  # 自检路径是同步的（阻塞没关系）：等网页内容真的回来再报结果
  if ($ok) {
    foreach ($h in @([DshFloatNative]::FindMainWindows([uint32[]]@($script:DshPids)))) {
      if ([DshFloatNative]::IsWindowVisible($h)) {
        if (Test-DshFrozen) { [void](Wait-DshContentAlive -Handle $h) }
        break
      }
    }
  }
  # 注意：网页内容是异步重建的，可能比这里的等待还慢。自检只报告"窗口有没有被显示出来"，
  # 内容是否已经重建用日志里的 content 行判断，不因此报失败。
  if (-not $ok) {
    Write-Log 'restore-only result: FAILED (no window shown)'
  } elseif (Test-DshFrozen) {
    Write-Log 'restore-only result: OK (window shown; web content is still rebuilding)'
  } else {
    Write-Log 'restore-only result: OK (window shown; web content alive)'
  }
  if ($ok) { exit 0 }
  exit 2
}

# ─────────────────────────────────────────────────────────────────────────────
# 建窗
# ─────────────────────────────────────────────────────────────────────────────
Write-Log 'loading WPF assemblies'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:App = New-Object System.Windows.Application
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

$script:Window = New-Object System.Windows.Window
$script:Window.WindowStyle = [System.Windows.WindowStyle]::None
$script:Window.AllowsTransparency = $true          # 逐像素透明 → 圆形边缘抗锯齿
$script:Window.Background = [System.Windows.Media.Brushes]::Transparent
$script:Window.Topmost = $true
$script:Window.ShowInTaskbar = $false
$script:Window.ResizeMode = [System.Windows.ResizeMode]::NoResize
$script:Window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
$script:Window.Width = [double]$Size
$script:Window.Height = [double]$Size
$script:Window.Title = 'DSH'
$script:Window.Visibility = [System.Windows.Visibility]::Hidden
try { $script:Window.ToolTip = '左键拖动移动位置 · 单击打开 DSH' } catch { }

# 内容：白底圆 → DSH 图标 → 一圈很淡的描边；整块内容裁成圆形。
$grid = New-Object System.Windows.Controls.Grid

$clip = New-Object System.Windows.Media.EllipseGeometry
$clip.Center = New-Object System.Windows.Point(([double]$Size / 2.0), ([double]$Size / 2.0))
$clip.RadiusX = ([double]$Size / 2.0)
$clip.RadiusY = ([double]$Size / 2.0)
$grid.Clip = $clip

$white = New-Object System.Windows.Shapes.Ellipse
$white.Fill = [System.Windows.Media.Brushes]::White
$grid.Children.Add($white) | Out-Null

# 图标：优先用 DSH 安装目录里的 icon.png（1024×1024 虎鲸标）。图标自身底色接近纯白，
# 铺满整个圆并裁圆后，方形底色四角被裁掉，视觉上就是"白色圆 + 虎鲸"。
$iconSource = $null
if (-not [string]::IsNullOrWhiteSpace($IconPath) -and (Test-Path -LiteralPath $IconPath)) {
  try {
    $bytes = [System.IO.File]::ReadAllBytes($IconPath)
    $stream = New-Object System.IO.MemoryStream
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Position = 0
    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.StreamSource = $stream
    $bitmap.EndInit()
    $bitmap.Freeze()
    $stream.Dispose()
    $iconSource = $bitmap
    Write-Log 'icon loaded'
  } catch {
    Write-Log ('icon load failed: ' + $_.Exception.Message)
    $iconSource = $null
  }
} else {
  Write-Log 'icon path missing or not found, using DSH text fallback'
}

if ($null -ne $iconSource) {
  $image = New-Object System.Windows.Controls.Image
  $image.Source = $iconSource
  $image.Stretch = [System.Windows.Media.Stretch]::Uniform
  [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($image, [System.Windows.Media.BitmapScalingMode]::HighQuality)
  $grid.Children.Add($image) | Out-Null
} else {
  $text = New-Object System.Windows.Controls.TextBlock
  $text.Text = 'DSH'
  $text.FontSize = ([double]$Size * 0.30)
  $text.FontWeight = [System.Windows.FontWeights]::SemiBold
  $text.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(45, 55, 72))
  $text.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $text.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $grid.Children.Add($text) | Out-Null
}

$ring = New-Object System.Windows.Shapes.Ellipse
$ring.Stroke = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(30, 15, 23, 42))
$ring.StrokeThickness = 1.0
$ring.IsHitTestVisible = $false
$grid.Children.Add($ring) | Out-Null

$script:Window.Content = $grid

# 左键：拖动即移动（WPF 原生 DragMove，可拖到任意位置）；几乎没动 → 视为单击 → 唤回 DSH
$grid.Add_MouseLeftButtonDown({
    try {
      $script:DragFromLeft = $script:Window.Left
      $script:DragFromTop = $script:Window.Top
      $script:Window.DragMove()
      $dx = [Math]::Abs($script:Window.Left - $script:DragFromLeft)
      $dy = [Math]::Abs($script:Window.Top - $script:DragFromTop)
      if (($dx -lt 3.0) -and ($dy -lt 3.0)) {
        # 单击（含快速连点，一律只做"唤回 DSH"这一件事，绝不动任何进程）
        Invoke-OpenDsh
      } else {
        Save-Position
        Write-Log ('moved to ' + $script:Window.Left + ',' + $script:Window.Top)
      }
    } catch {
      Write-Log ('drag failed: ' + $_.Exception.Message)
    }
  })

$script:Window.Add_Closed({
    Write-Log 'window closed, shutting down'
    try { $script:App.Shutdown() } catch { }
  })

# ─────────────────────────────────────────────────────────────────────────────
# 轮询
# ─────────────────────────────────────────────────────────────────────────────
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(150, $PollMs))
$script:Timer.Add_Tick({ Update-Visibility })
$script:Timer.Start()

Update-DshCandidates
Restore-Position
Update-Visibility
Write-Log 'floating ball ready'

try {
  $script:App.Run() | Out-Null
} catch {
  Write-Log ('run failed: ' + $_.Exception.Message)
  exit 1
}

Write-Log 'floating ball stopped'
exit 0
