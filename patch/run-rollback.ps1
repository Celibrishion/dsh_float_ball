#requires -Version 5.1
# 应急回滚：把备份的原始 app.asar 放回去
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); chcp 65001 > $null } catch { }
$PatchDir = $PSScriptRoot

Write-Host ''
Write-Host '  DSH 恢复（回滚到原始 app.asar）' -ForegroundColor Cyan
Write-Host ''

# 等 DSH 完全退出
$w = 0
while (@(Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue).Count -gt 0) {
  if ($w -eq 0) { Write-Host '  [等待] 请完全退出 DSH（含托盘图标）…' }
  Start-Sleep -Seconds 3; $w += 3
  if ($w % 30 -eq 0) { Write-Host ('         …已等待 ' + $w + ' 秒') }
}
Write-Host '  DSH 已退出。'

$bak = Join-Path $PatchDir 'backup\app.asar.original'
if (-not (Test-Path $bak)) {
  Write-Host ('  [X] 没有备份可回滚: ' + $bak) -ForegroundColor Red
  Write-Host '      备份是在第一次打补丁时自动创建的。'
  Write-Host '      如果从没打过补丁，就不需要回滚。'
  exit 1
}

# 定位 DSH 安装目录：缓存文件 → 运行过的进程 → 常见位置
# 注意：这里不能用正则——PowerShell 5.1 的解析器会把单引号串里的 [A-Za-z]
#       当成 [type] 类型字面量，导致整段脚本在解析期报错（踩过）。
$cands = @()
$cache = Join-Path $PatchDir 'dsh-root.txt'
if (Test-Path -LiteralPath $cache) {
  $c = ([string](Get-Content -LiteralPath $cache -Raw -ErrorAction SilentlyContinue)).Trim()
  if ($c) { $cands += $c }
}
$procs = Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue
foreach ($q in $procs) {
  $cmd = [string]$q.CommandLine
  if (-not $cmd) { continue }
  $i = $cmd.IndexOf('\resources\app.asar')
  if ($i -le 0) { continue }
  $prefix = $cmd.Substring(0, $i)
  $start = $prefix.LastIndexOf('"')
  if ($start -lt 0) { $start = -1 }
  $sp = $prefix.IndexOf(' ', $start + 1)
  $cand = if ($sp -gt ($start + 1)) { $prefix.Substring($start + 1, $sp - $start - 1) } else { $prefix.Substring($start + 1) }
  $cand = $cand.Trim()
  if ($cand) { $cands += $cand }
}
foreach ($g in @('D:\DeepSeek', "$env:LOCALAPPDATA\Programs\DeepSeek Harness", 'C:\Program Files\DeepSeek Harness')) {
  if ($g) { $cands += $g }
}

$target = $null
foreach ($r in ($cands | Select-Object -Unique)) {
  if (-not $r) { continue }
  if (Test-Path (Join-Path $r 'resources\app.asar')) { $target = Join-Path $r 'resources\app.asar'; break }
}
if (-not $target) {
  Write-Host '  [X] 找不到 DSH 的 app.asar' -ForegroundColor Red
  Write-Host ('      请手动把 ' + $bak + ' 复制到 <DSH安装目录>\resources\app.asar')
  exit 1
}
Write-Host ('  目标: ' + $target)
Copy-Item -LiteralPath $bak -Destination $target -Force
$ok = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $bak -Algorithm SHA256).Hash
Write-Host ('  回滚后哈希一致 = ' + $ok) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
if ($ok) { Write-Host '  [OK] 已恢复到原始版本，可以启动 DSH' -ForegroundColor Green; exit 0 } else { exit 1 }