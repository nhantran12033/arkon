<#
  Arkon — Build production trên server Windows
  =============================================
  Chạy bằng PowerShell (không cần admin, trừ khi thư mục bị khoá quyền):

      cd D:\Storm12\Arkon\arkon
      .\deploy\win\build.ps1

  Chạy lại script này mỗi lần deploy code mới (git pull).
  Sau khi build xong nhớ restart service:  .\deploy\win\restart-services.ps1
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Resolve-Path "$PSScriptRoot\..\.."),
    # Domain public của portal. Giá trị này được NHÚNG CỨNG vào bundle JS lúc build,
    # đổi domain là phải build lại frontend.
    [string]$PublicUrl = $env:ARKON_PUBLIC_URL
)

$ErrorActionPreference = "Stop"

if (-not $PublicUrl) {
    throw "Chua dat -PublicUrl (vd: https://arkon.congty.com) hoac bien moi truong ARKON_PUBLIC_URL."
}

Write-Host "==> Project root : $ProjectRoot"
Write-Host "==> Public URL   : $PublicUrl"

# ---------------------------------------------------------------- Backend
$venv = Join-Path $ProjectRoot ".venv"
if (-not (Test-Path $venv)) {
    Write-Host "==> Tao virtualenv .venv"
    python -m venv $venv
}
$py = Join-Path $venv "Scripts\python.exe"

Write-Host "==> Cai dependencies backend"
& $py -m pip install --upgrade pip
& $py -m pip install -e "$ProjectRoot"

Write-Host "==> Chay migration database"
Push-Location $ProjectRoot
& (Join-Path $venv "Scripts\alembic.exe") upgrade head
Pop-Location

# ---------------------------------------------------------------- Frontend
$fe = Join-Path $ProjectRoot "frontend"
Push-Location $fe

Write-Host "==> Cai dependencies frontend"
npm ci

Write-Host "==> Build Next.js (standalone)"
$env:NEXT_PUBLIC_API_URL = $PublicUrl
$env:NEXT_TELEMETRY_DISABLED = "1"
$env:NODE_ENV = "production"
npm run build

# Next standalone khong tu copy public/ va .next/static -> phai copy thu cong
$standalone = Join-Path $fe ".next\standalone"
if (-not (Test-Path $standalone)) {
    throw "Khong tim thay .next\standalone. Kiem tra next.config.ts co output: 'standalone' khong."
}

Write-Host "==> Copy public/ va .next/static vao standalone"
Copy-Item -Recurse -Force (Join-Path $fe "public")      (Join-Path $standalone "public")
New-Item -ItemType Directory -Force -Path (Join-Path $standalone ".next") | Out-Null
Copy-Item -Recurse -Force (Join-Path $fe ".next\static") (Join-Path $standalone ".next\static")

Pop-Location

Write-Host ""
Write-Host "==> BUILD XONG."
Write-Host "    Buoc tiep theo: .\deploy\win\restart-services.ps1  (hoac install-services.ps1 neu lan dau)"
