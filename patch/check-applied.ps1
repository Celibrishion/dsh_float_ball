#requires -Version 5.1
# 独立复核：直接读 app.asar，确认 lib/main.js 的大小
param([string]$DshRoot = '')
$ErrorActionPreference = 'Continue'
$PatchDir = $PSScriptRoot
if (-not $DshRoot) {
  $cache = Join-Path $PatchDir 'dsh-root.txt'
  if (Test-Path -LiteralPath $cache) {
    # UTF-8 读取，兼容含中文的安装路径
    $DshRoot = ([string](Get-Content -LiteralPath $cache -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)).Trim()
  }
}
if (-not $DshRoot) {
  Write-Host '  cannot resolve install dir (no dsh-root.txt cache)'
  exit 1
}
  $asar = Join-Path $DshRoot 'resources\app.asar'
  $exe  = Join-Path $DshRoot 'DeepSeek Harness.exe'
  # 必须两样都在，才算 DSH 安装目录（否则会把别的 Electron 应用当成 DSH）
  if (-not (Test-Path -LiteralPath $asar) -or -not (Test-Path -LiteralPath $exe)) {
    Write-Host ('  not a DSH install dir: ' + $DshRoot)
    Write-Host '  (needs both DeepSeek Harness.exe and resources\app.asar)'
    Write-Host '  hint: run apply-patch.ps1 -Action Status, or pass -DshRoot "<DSH dir>"'
    exit 1
  }
$mainSize = 0
try {
  $fs = [System.IO.File]::Open($asar, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $h = New-Object byte[] 16
    [void]$fs.Read($h, 0, 16)
    $hs = [BitConverter]::ToUInt32($h, 12)
    $jb = New-Object byte[] $hs
    [void]$fs.Read($jb, 0, $hs)
    $json = ([System.Text.Encoding]::UTF8.GetString($jb)).TrimEnd([char]0, [char]32, [char]10, [char]13)
    $o = $json | ConvertFrom-Json
    $mainSize = [int]$o.files.lib.files.'main.js'.size
  } finally { $fs.Close() }
} catch {
  Write-Host ('  read failed: ' + $_.Exception.Message)
  Write-Host ('  target path: ' + $asar)
  exit 1
}
Write-Host ('  target: ' + $asar)
Write-Host ('  lib/main.js = ' + $mainSize + ' bytes   (original 490173 / patch v2 491921)')
if ($mainSize -eq 491921) {
  Write-Host '  [OK] patch v2 is live' -ForegroundColor Green
  exit 0
} elseif ($mainSize -eq 490173) {
  Write-Host '  [X] not patched (still original)' -ForegroundColor Red
  exit 1
} elseif ($mainSize -eq 491685) {
  Write-Host '  [X] still patch v1 (old version)' -ForegroundColor Red
  exit 1
} else {
  Write-Host ('  [X] unexpected size: ' + $mainSize) -ForegroundColor Red
  exit 1
}
