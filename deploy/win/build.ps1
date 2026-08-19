<#
  Arkon — Build production trên máy deploy
  =========================================
  Chạy bằng PowerShell (không cần admin):

      cd C:\Storm12\Deployment\Arkon\arkon
      .\deploy\win\build.ps1 -PublicUrl "https://192.168.200.52:44380"

  Chạy lại script này mỗi lần deploy code mới (git pull).
  Sau khi build xong nhớ restart service:  .\deploy\win\restart-services.ps1
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Resolve-Path "$PSScriptRoot\..\.."),

    # Địa chỉ public của portal. Giá trị này được NHÚNG CỨNG vào bundle JS lúc build,
    # đổi IP/port là phải build lại frontend.
    [string]$PublicUrl = $env:ARKON_PUBLIC_URL,

    # Bản Python dùng để tạo venv. "3.13" -> py -3.13
    [string]$PythonVersion = "3.13",

    # Bỏ qua bước alembic upgrade head (dùng khi DB chưa sẵn sàng)
    [switch]$SkipMigration
)

$ErrorActionPreference = "Stop"

if (-not $PublicUrl) {
    throw "Chua dat -PublicUrl (vd: https://192.168.200.52:44380) hoac bien moi truong ARKON_PUBLIC_URL."
}

Write-Host "==> Project root : $ProjectRoot"
Write-Host "==> Public URL   : $PublicUrl"
Write-Host "==> Python       : $PythonVersion"

# ---------------------------------------------------------------- Backend
$venv = Join-Path $ProjectRoot ".venv"
$py   = Join-Path $venv "Scripts\python.exe"

if (-not (Test-Path $py)) {
    Write-Host "==> Tao virtualenv .venv bang Python $PythonVersion"
    if (-not (Get-Command py.exe -ErrorAction SilentlyContinue)) {
        throw "Khong tim thay Python launcher 'py'. Cai Python tu python.org truoc."
    }
    & py "-$PythonVersion" -m venv $venv
    if ($LASTEXITCODE -ne 0) {
        throw "Khong tao duoc venv bang Python $PythonVersion. Kiem tra 'py --list'."
    }
}

# Chan truong hop venv cu con sot lai o ban Python khac
$actual = (& $py -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')").Trim()
if ($actual -ne $PythonVersion) {
    throw @"
.venv dang la Python $actual, khong phai $PythonVersion.
Xoa roi tao lai:
    Remove-Item -Recurse -Force "$venv"
    .\deploy\win\build.ps1 -PublicUrl "$PublicUrl" -PythonVersion $PythonVersion
"@
}
Write-Host "==> venv OK: Python $actual"

Write-Host "==> Cai dependencies backend"
& $py -m pip install --upgrade pip
& $py -m pip install -e "$ProjectRoot"

if (-not $SkipMigration) {
    Write-Host "==> Chay migration database"
    Push-Location $ProjectRoot
    & (Join-Path $venv "Scripts\alembic.exe") upgrade head
    Pop-Location
} else {
    Write-Warning "==> Bo qua migration (-SkipMigration). Nho chay 'alembic upgrade head' truoc khi start service."
}

# ---------------------------------------------------------------- Frontend
$fe = Join-Path $ProjectRoot "frontend"
Push-Location $fe

Write-Host "==> Cai dependencies frontend"
npm ci

Write-Host "==> Build Next.js (standalone)"
$env:NEXT_PUBLIC_API_URL     = $PublicUrl
$env:NEXT_TELEMETRY_DISABLED = "1"
$env:NODE_ENV                = "production"
npm run build

# Next standalone khong tu copy public/ va .next/static -> phai copy thu cong
$standalone = Join-Path $fe ".next\standalone"
if (-not (Test-Path $standalone)) {
    throw "Khong tim thay .next\standalone. Kiem tra next.config.ts co output: 'standalone' khong."
}

Write-Host "==> Copy public/ va .next/static vao standalone"
Copy-Item -Recurse -Force (Join-Path $fe "public") (Join-Path $standalone "public")
New-Item -ItemType Directory -Force -Path (Join-Path $standalone ".next") | Out-Null
Copy-Item -Recurse -Force (Join-Path $fe ".next\static") (Join-Path $standalone ".next\static")

Pop-Location

Write-Host ""
Write-Host "==> BUILD XONG."
Write-Host "    Lan dau      : .\deploy\win\install-services.ps1   (Administrator)"
Write-Host "    Deploy lai   : .\deploy\win\restart-services.ps1   (Administrator)"
