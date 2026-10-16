#requires -Version 5.1
# 由 apply-patch.cmd 调用：等待 DSH 完全退出 → 打补丁 → 独立复核
$ErrorActionPreference = 'Continue'
try {
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  chcp 65001 > $null
} catch { }

$PatchDir = $PSScriptRoot
$Status = Join-Path $PatchDir 'apply-status.log'
function Say { param([string]$m) Write-Host $m }
function Log { param([string]$m) Add-Content -LiteralPath $Status -Value ('[' + (Get-Date).ToString('HH:mm:ss') + '] ' + $m) -Encoding UTF8 }

Remove-Item -LiteralPath $Status -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  DSH 悬浮球热补丁' -ForegroundColor Cyan
Write-Host '  关闭到托盘后，点悬浮球立刻可用（保留托盘语义）' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Say ''
Say '  本工具会修改 DSH 安装目录下的 resources\app.asar：'
Say '    把「关闭到托盘」从 window.hide() 改成「移出屏幕 + 收起任务栏图标」，'
Say '    这样网页内容不会被销毁，点悬浮球即可立刻恢复使用。'
Say '  会先自动备份原包；出问题可双击 rollback.cmd 一键恢复。'
Log 'run-apply 启动'

# 等待 DSH 完全退出
$waited = 0
while (@(Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue).Count -gt 0) {
  if ($waited -eq 0) {
    Write-Host ''
    Say '  [等待] DSH 仍在运行。请完全退出它 —— 包括右下角托盘里的图标（右键 → 退出）。'
    Say '         检测到退出后会自动继续，请稍候…'
  }
  Start-Sleep -Seconds 3
  $waited += 3
  if ($waited % 30 -eq 0) { Say ('         …已等待 ' + $waited + ' 秒') }
}
Log 'DSH 已退出'
Say ''
Say '  [就绪] DSH 已完全退出。'
Start-Sleep -Seconds 3

Write-Host ''
Write-Host '--- 当前状态 ---' -ForegroundColor White
$statusOut = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PatchDir 'apply-patch.ps1') -Action Status 2>&1)
$statusOut | ForEach-Object { Write-Host $_ }
Log '状态已显示'

# 从 Status 输出里解析安装目录（绝不硬编码）
$instRoot = $null
foreach ($line in $statusOut) {
  if ($line -match 'DSH 安装目录[:：]\s*(.+?)\s*$') { $instRoot = $Matches[1].Trim(); break }
}

Write-Host ''
Write-Host ('-' * 60)
$go = Read-Host '  确认打补丁? 输入 Y 继续，其它键取消'
if ($go -notmatch '^[Yy]') {
  Say ''
  Say '  已取消，未做任何修改。'
  Log '用户取消'
  exit 0
}

Write-Host ''
$applyOut = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PatchDir 'apply-patch.ps1') -Action Apply 2>&1)
$code = $LASTEXITCODE
$applyOut | ForEach-Object { Write-Host $_ }
Log ("Apply 退出码 = " + $code)

# 独立复核：交给 check-applied.ps1（不再解析 Status 的文本输出，那样太脆）
Write-Host ''
Write-Host '--- 独立复核 ---' -ForegroundColor White
$chk = Join-Path $PatchDir 'check-applied.ps1'
$chkOut = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $chk 2>&1)
$chkCode = $LASTEXITCODE
foreach ($l in $chkOut) { Write-Host $l }
Log ('复核退出码=' + $chkCode)

# 判定：Apply 成功 **且** 独立复核确认补丁已生效
$ok = ($code -eq 0) -and ($chkCode -eq 0)
if ($ok) {
  Write-Host ''
  Write-Host '  补丁已生效，可以启动 DSH 了。' -ForegroundColor Green
  Log '补丁已生效'
  exit 0
} else {
  Write-Host ''
  Write-Host '  补丁未确认生效，请把上面的输出发给我。' -ForegroundColor Red
  Log '补丁未确认生效'
  exit 1
}