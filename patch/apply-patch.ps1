#requires -Version 5.1
<#
  dsh-float-ball —— DSH「关闭到托盘」热补丁工具

  作用：把 DSH 桌面壳的 hideMainWindow() 从 window.hide() 改成「最小化 + 收起任务栏图标」。
         window.hide() 会销毁 Chromium 的网页内容子窗口(Chrome_RenderWidgetHostHWND)，
         之后外部无法让内容复活（点悬浮球只能得到一帧死画面）。
         最小化不会销毁 WebContents，且配合 setSkipTaskbar 仍保留托盘语义。

  用法（Apply/Rollback 需要 DSH 已完全退出）：
    .\apply-patch.ps1 -Action Status
    .\apply-patch.ps1 -Action Apply
    .\apply-patch.ps1 -Action Rollback
    .\apply-patch.ps1 -Action Verify

  DSH 每次更新会覆盖 app.asar，更新后重新运行 -Action Apply。
#>
[CmdletBinding()]
param(
  [ValidateSet('Status', 'Apply', 'Rollback', 'Verify')][string]$Action = 'Status',
  [string]$DshRoot = '',
  [switch]$SkipProcessCheck
)

$ErrorActionPreference = 'Stop'
$PatchDir = $PSScriptRoot
$BackupDir = Join-Path $PatchDir 'backup'
$WorkDir = Join-Path $PatchDir 'work'
$AsarToolDir = Join-Path $WorkDir 'asar-tool'
$OfficialCheck = Join-Path $AsarToolDir 'check-official.cjs'

function Write-Step { param([string]$m) Write-Host "  $m" }
function Write-Ok { param([string]$m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Bad { param([string]$m) Write-Host "  [X] $m" -ForegroundColor Red }
function Write-Info { param([string]$m) Write-Host "  - $m" -ForegroundColor DarkGray }
function Show-NodeOutput {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line.Trim().Length -gt 0) { Write-Host "    $line" }
  }
}

function Test-DshDir {
  param([string]$Dir)
  if (-not $Dir) { return $false }
  $exe = Join-Path $Dir 'DeepSeek Harness.exe'
  $asar = Join-Path $Dir 'resources\app.asar'
  return ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $asar))
}

function Find-DshRootHere {
  param([string]$Base)
  if (-not $Base -or -not (Test-Path -LiteralPath $Base)) { return $null }
  if (Test-DshDir $Base) { return $Base }
  $subs = Get-ChildItem -LiteralPath $Base -Directory -ErrorAction SilentlyContinue
  foreach ($s in $subs) {
    if (Test-DshDir $s.FullName) { return $s.FullName }
  }
  return $null
}

function Resolve-DshRoot {
  # 0) 缓存优先
  $cache = Join-Path $PatchDir 'dsh-root.txt'
  if (Test-Path -LiteralPath $cache) {
    $cached = ([string](Get-Content -LiteralPath $cache -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim()
    if (Test-DshDir $cached) { return $cached }
    Remove-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue
  }
  # 1) -DshRoot 参数
  if (Test-DshDir $DshRoot) { return $DshRoot }
  # 2) 运行中的进程
  $p = Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($p -and $p.Path) {
    $cand = Split-Path -Parent $p.Path
    if (Test-DshDir $cand) { return $cand }
  }
  # 3) 环境变量（DSH 会话内会设置）
  if ($env:DSH_DESKTOP_NODE_EXECUTABLE) {
    $cand = Split-Path -Parent $env:DSH_DESKTOP_NODE_EXECUTABLE
    if (Test-DshDir $cand) { return $cand }
  }
  # 4) 进程命令行（不用正则：PS 5.1 会把单引号串里的 [A-Za-z] 当类型字面量）
  $procs = Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue
  foreach ($q in $procs) {
    $cmd = [string]$q.CommandLine
    if (-not $cmd) { continue }
    $idx = $cmd.IndexOf('\resources\app.asar')
    if ($idx -le 0) { continue }
    $prefix = $cmd.Substring(0, $idx)
    $st = $prefix.LastIndexOf('"')
    if ($st -lt 0) { $st = -1 }
    $sp = $prefix.IndexOf(' ', $st + 1)
    $cand = if ($sp -gt ($st + 1)) { $prefix.Substring($st + 1, $sp - $st - 1) } else { $prefix.Substring($st + 1) }
    $cand = $cand.Trim()
    if (Test-DshDir $cand) { return $cand }
  }
  # 5) 注册表：卸载信息里常见 DisplayIcon / InstallLocation
  $regRoots = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  )
  foreach ($rr in $regRoots) {
    $keys = Get-ChildItem -LiteralPath $rr -ErrorAction SilentlyContinue
    foreach ($k in $keys) {
      $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
      if (-not $props) { continue }
      $name = [string]$props.DisplayName
      if ($name -notmatch 'DeepSeek|Harness') { continue }
      foreach ($cand in @([string]$props.InstallLocation, [string]$props.DisplayIcon)) {
        if (-not $cand) { continue }
        $dir = $cand.Trim('"')
        if ($dir -match '\.exe$') { $dir = Split-Path -Parent $dir }
        if (Test-DshDir $dir) { return $dir }
      }
    }
  }
  # 6) 常见位置扫描（含一层子目录）
  $bases = @(
    'D:\DeepSeek', 'C:\DeepSeek',
    (Join-Path $env:LOCALAPPDATA 'Programs'),
    (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'),
    $env:ProgramFiles, ${env:ProgramFiles(x86)},
    'D:\', 'E:\', 'C:\'
  ) | Where-Object { $_ }
  foreach ($b in $bases) {
    $hit = Find-DshRootHere -Base $b
    if ($hit) { return $hit }
  }
  # 7) 交互式询问（最后手段）
  Write-Host ''
  Write-Host '  [无法自动定位 DSH] 请手动输入 DSH 安装目录。' -ForegroundColor Yellow
  Write-Host '  提示：就是含 "DeepSeek Harness.exe" 的那个文件夹（里面同时有 resources\app.asar）'
  Write-Host '  例如: D:\DeepSeek' -ForegroundColor DarkGray
  Write-Host ''
  for ($try = 1; $try -le 3; $try++) {
    $in = Read-Host ('  请输入 DSH 安装目录 (第 ' + $try + '/3 次, 直接回车放弃)')
    if (-not $in) { break }
    $in = $in.Trim().Trim('"').Trim("'")
    if (Test-DshDir $in) { return $in }
    if (Test-Path -LiteralPath $in) {
      $hit = Find-DshRootHere -Base $in
      if ($hit) { return $hit }
    }
    Write-Host ('  不是 DSH 目录（缺少 DeepSeek Harness.exe 或 resources\app.asar）: ' + $in) -ForegroundColor Red
  }
  throw 'cannot locate DSH install dir; pass -DshRoot <dir> where <dir>\resources\app.asar exists'
}
function Resolve-Node {
  param([string]$Root)
  $cands = @()
  $cands += (Join-Path $Root 'resources\runtime\primary-runtime\dependencies\node\bin\node.exe')
  $cands += 'node.exe'
  foreach ($c in $cands) {
    try { if ($c -eq 'node.exe' -or (Test-Path $c)) { return $c } } catch { }
  }
  throw 'cannot find node.exe'
}

function Invoke-Node {
  param([string[]]$NodeArgs)
  # NOTE: must capture via assignment; `| Out-Null` would leave $out empty,
  # and -OutputVariable does not work for native commands here.
  $out = $null
  $out = & $NodeExe @NodeArgs 2>&1
  $code = $LASTEXITCODE
  $out = @($out)
  return [pscustomobject]@{ Output = ($out -join [Environment]::NewLine); Code = $code }
}

function Get-AsarInfo {
  param([string]$AsarPath)
  $len = (Get-Item -LiteralPath $AsarPath).Length
  $fs = [System.IO.File]::Open($AsarPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $h = New-Object byte[] 16
    [void]$fs.Read($h, 0, 16)
    $headerSize = [BitConverter]::ToUInt32($h, 12)
    $jb = New-Object byte[] $headerSize
    [void]$fs.Read($jb, 0, $headerSize)
    $json = ([System.Text.Encoding]::UTF8.GetString($jb)).TrimEnd([char]0, [char]32, [char]10, [char]13)
    $obj = $json | ConvertFrom-Json
    $mainSize = -1
    try { $mainSize = [int]$obj.files.lib.files.'main.js'.size } catch { $mainSize = -1 }
    return [pscustomobject]@{
      Path = $AsarPath; Size = $len; HeaderSize = $headerSize
      MainJsSize = $mainSize; HasMarker = $json.Contains('floatBallUnpark')
    }
  } finally { $fs.Close() }
}

function Get-DshProcessCount {
  return @(Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue).Count
}

# ---------------------------------------------------------------- main
$root = Resolve-DshRoot
Write-Output ('  [resolve] install dir = ' + $root + '   (length ' + $root.Length + ')')
try {
  # 必须用 UTF-8：安装路径可能含中文，ASCII 会把中文写成 ? 导致缓存失效
  Set-Content -LiteralPath (Join-Path $PatchDir 'dsh-root.txt') -Value $root -Encoding UTF8
} catch { }
$NodeExe = Resolve-Node -Root $root
$asar = Join-Path $root 'resources\app.asar'
$running = Get-DshProcessCount

Write-Host ''
Write-Host 'dsh-float-ball hot patch tool' -ForegroundColor Cyan
Write-Info ("DSH install dir : " + $root)
Write-Info ("app.asar        : " + $asar)
Write-Info ("node            : " + $NodeExe)
Write-Info ("DSH processes   : " + $running + $(if ($running -gt 0) { '  (running - Apply/Rollback need it fully closed)' }))
Write-Host ''

switch ($Action) {

  'Status' {
    $st = Get-AsarInfo -AsarPath $asar
    Write-Host 'current app.asar:' -ForegroundColor White
    Write-Step ("size        : " + $st.Size + " bytes")
    Write-Step ("header size : " + $st.HeaderSize)
    Write-Step ("lib/main.js : " + $st.MainJsSize + " bytes   (original 490173 / patch v1 491685 / patch v2 491921)")
    if ($st.HasMarker) { Write-Ok 'patched (hideMainWindow rewritten, floatBallUnpark present)' }
    elseif ($st.MainJsSize -eq 491921) { Write-Ok 'patch v2 is live (hideMainWindow rewritten with minimize + floatBallUnpark)' }
    elseif ($st.MainJsSize -eq 491685) { Write-Bad 'patch v1 is installed (older version, has the tray-icon bug) -> run -Action Apply to upgrade to v2' }
    elseif ($st.MainJsSize -eq 490173) { Write-Bad 'not patched (still original window.hide()) -> run -Action Apply' }
    else { Write-Bad ("unexpected lib/main.js size: " + $st.MainJsSize) }
    $bak = Join-Path $BackupDir 'app.asar.original'
    if (Test-Path $bak) { Write-Info ("pristine backup: " + $bak + " (" + (Get-Item $bak).Length + " bytes)") }
    else { Write-Info 'no pristine backup yet (first Apply will create it)' }
  }

  'Verify' {
    $r = Invoke-Node @((Join-Path $PatchDir 'verify-asar.cjs'), $asar)
    Show-NodeOutput $r.Output
    if ($r.Code -eq 0) { Write-Ok 'structure check passed' } else { Write-Bad ("structure check failed (exit " + $r.Code + ")") }
  }

  'Apply' {
    if ($running -gt 0 -and -not $SkipProcessCheck) {
      Write-Bad ("DSH is running (" + $running + " processes); app.asar is locked.")
      Write-Step 'Fully quit DSH (including the tray icon) and run Apply again.'
      exit 2
    }
    if (-not (Test-Path $asar)) { Write-Bad ("target missing: " + $asar); exit 1 }
    if (-not (Test-Path (Join-Path $root 'DeepSeek Harness.exe'))) {
      Write-Bad ("this does not look like a DSH install (no DeepSeek Harness.exe): " + $root)
      Write-Step 'Use -DshRoot to point at the right directory. Nothing was modified.'
      exit 1
    }
    New-Item -ItemType Directory -Force -Path $BackupDir, $WorkDir | Out-Null

    # 1) 原始备份（回滚与"永远以原始包为基准"都靠它）
    $bak = Join-Path $BackupDir 'app.asar.original'
    $bakBase = $bak
    if (-not (Test-Path -LiteralPath $asar)) { Write-Bad ("source app.asar not found: " + $asar); exit 1 }
    $bakOk = $true
    if (-not (Test-Path -LiteralPath $bak)) {
      try {
        Copy-Item -LiteralPath $asar -Destination $bak -Force -ErrorAction Stop
      } catch {
        $bakOk = $false
        Write-Bad "backup failed:"
        Write-Step ("  " + $_.Exception.Message)
      }
      if ($bakOk -and (Test-Path -LiteralPath $bak)) {
        Write-Ok ('pristine backup created: ' + $bak)
      } else {
        Write-Bad "Could not create the pristine backup. Details:"
        Write-Step ("  source      : " + $asar + "   exists=" + (Test-Path -LiteralPath $asar))
        Write-Step ("  destination : " + $bak)
        Write-Step ("  dest dir    : " + $BackupDir + "   exists=" + (Test-Path -LiteralPath $BackupDir))
        $srcSize = "n/a"
        try { $srcSize = (Get-Item -LiteralPath $asar).Length } catch { }
        Write-Step ("  source size : " + $srcSize + " bytes")
        Write-Step "  Tip: a path with Chinese characters or an over-long path can fail here."
        Write-Step "       Try moving the extracted folder to a short ASCII path such as E:\dshpatch and retry."
        exit 1
      }
    } else {
      Write-Info ("using existing pristine backup: " + $bak)
    }

    # 2) extract baseline lib/main.js FROM THE PRISTINE BACKUP
    $mainOrig = Join-Path $WorkDir 'main.orig.js'
    $r1 = Invoke-Node @((Join-Path $PatchDir 'extract-main.cjs'), $bakBase, 'lib/main.js', $mainOrig)
    if ($r1.Code -ne 0) { Write-Bad ("extract failed: " + $r1.Output); exit 1 }
    Write-Ok 'baseline lib/main.js extracted from pristine backup'

    # 3) generate patched lib/main.js
    $mainPatched = Join-Path $WorkDir 'main.patched.js'
    $r2 = Invoke-Node @((Join-Path $PatchDir 'gen-patch.cjs'), $mainOrig, $mainPatched)
    Show-NodeOutput $r2.Output
    if ($r2.Code -ne 0) { Write-Bad 'patch generation failed (hideMainWindow anchor not found?)'; exit 1 }

    # 4) repack (baseline = pristine backup)
    $out = Join-Path $WorkDir 'app.patched.asar'
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    $r3 = Invoke-Node @((Join-Path $PatchDir 'repack2.cjs'), '--src', $bakBase, '--out', $out, '--set', 'lib/main.js', '--content', $mainPatched)
    Show-NodeOutput $r3.Output
    if ($r3.Code -ne 0) { Write-Bad 'repack failed'; exit 1 }

    # 5a) own verifier
    $r4 = Invoke-Node @((Join-Path $PatchDir 'verify-asar.cjs'), $out, $bakBase, '--allow', 'lib/main.js')
    Show-NodeOutput $r4.Output
    if ($r4.Code -ne 0) { Write-Bad 'self check failed -> aborted, nothing modified'; exit 1 }
    Write-Ok 'self check passed'

    # 5b) official parser verdict (Electron uses the same parser)
    # 官方校验器需要 @electron/asar；仓库里不含 node_modules，缺失时先尝试自动安装。
    # 装不上（离线 / 没有 pnpm）就降级成"只用自研校验"，并明确警告，而不是直接中止。
    if (-not (Test-Path $OfficialCheck)) {
      Write-Info 'official checker not present; installing @electron/asar (needs pnpm)...'
      try {
        & pnpm --dir $AsarToolDir install --registry https://registry.npmmirror.com 2>&1 | Out-Null
      } catch { }
    }
    if (-not (Test-Path $OfficialCheck)) {
      Write-Bad 'WARNING: official parser unavailable - continuing with the self check only.'
      Write-Step ('To enable the official verdict, run: pnpm --dir "' + $AsarToolDir + '" install')
      Write-Ok 'self check passed (official verdict skipped)'
    } else {
      Write-Info 'official @electron/asar verdict...'
      $savedLoc = (Get-Location).Path
      Set-Location $AsarToolDir
      try { $r5 = Invoke-Node @($OfficialCheck, $bakBase, $out) } finally { Set-Location $savedLoc }
      Show-NodeOutput $r5.Output
      # 兼容不同版本的裁决器输出（ASCII 标记 / 英文 / 中文）—— 少写一个就会把「通过」误判成「拒绝」
      $okOfficial = ($r5.Code -eq 0) -and ($r5.Output -match 'OFFICIAL_PARSER_ACCEPTED' -or $r5.Output -match 'official parser accepted' -or $r5.Output -match '官方解析器完全接受' -or $r5.Output -match '自研输出被官方接受')
      if (-not $okOfficial) { Write-Bad 'official parser rejected the archive -> aborted, nothing modified'; exit 1 }
      Write-Ok 'official parser verdict passed'
    }

    # 6) replace
    try {
      Copy-Item -LiteralPath $out -Destination $asar -Force
      Write-Ok 'app.asar replaced'
    } catch {
      Write-Bad ("replace failed: " + $_.Exception.Message)
      Write-Step 'Make sure DSH is fully closed, then retry.'
      exit 1
    }
    $st = Get-AsarInfo -AsarPath $asar
    if ($st.MainJsSize -eq 491921) { Write-Ok 'patch is live (lib/main.js = 491921 bytes)' }
    else { Write-Bad ("post-replace check unexpected: lib/main.js = " + $st.MainJsSize) }
    Write-Host ''
    Write-Host 'You can start DSH now.' -ForegroundColor Cyan
    Write-Step 'Test: close DSH to tray (X) -> the tray icon disappears; click the floating ball -> window returns usable.'
  }

  'Rollback' {
    if ($running -gt 0 -and -not $SkipProcessCheck) {
      Write-Bad 'DSH is running; cannot replace app.asar. Fully quit DSH and retry.'
      exit 2
    }
    $bak = Join-Path $BackupDir 'app.asar.original'
    if (-not (Test-Path $bak)) { Write-Bad ("no pristine backup to roll back to: " + $bak); exit 1 }
    Copy-Item -LiteralPath $bak -Destination $asar -Force
    $st = Get-AsarInfo -AsarPath $asar
    Write-Ok ("rolled back; lib/main.js = " + $st.MainJsSize + " bytes")
    $sha = Join-Path $BackupDir 'app.asar.original.sha256'
    if (Test-Path $sha) {
      $want = (Get-Content $sha -Raw).Trim()
      $got = (Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash
      if ($want -eq $got) { Write-Ok 'hash matches the pristine backup' } else { Write-Bad 'hash mismatch' }
    }
  }
}
