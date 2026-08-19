<#
  Arkon - Cai 4 Windows Service bang NSSM
  ========================================
  CHAY BANG POWERSHELL VOI QUYEN ADMINISTRATOR.

      cd C:\Storm12\Deployment\Arkon\arkon
      .\deploy\win\install-services.ps1

  Yeu cau: nssm.exe co trong PATH.
      Tai tu https://nssm.cc/download, giai nen, copy win64\nssm.exe vao C:\Windows\System32

  Service duoc tao:
      Arkon-API        uvicorn  127.0.0.1:5055
      Arkon-Worker     arq WorkerSettings        (pipeline ingest -> wiki)
      Arkon-Skills     arq SkillWorkerSettings
      Arkon-Frontend   node server.js  127.0.0.1:3000

  Chay lai script nay la an toan - no go service cu roi cai lai.
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Resolve-Path "$PSScriptRoot\..\.."),
    [string]$LogDir      = "C:\Logs\Arkon",

    # Tai khoan chay service. Mac dinh LocalSystem.
    # Neu can truy cap file share mang, dat lai thanh tai khoan domain.
    [string]$ServiceUser = ""
)

$ErrorActionPreference = "Stop"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Script nay phai chay bang PowerShell Administrator."
}
if (-not (Get-Command nssm.exe -ErrorAction SilentlyContinue)) {
    throw "Khong tim thay nssm.exe trong PATH. Tai tu https://nssm.cc/download roi copy vao C:\Windows\System32"
}

$py   = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
$fe   = Join-Path $ProjectRoot "frontend\.next\standalone"
$node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
if (-not $node) { throw "Khong tim thay node.exe trong PATH. Cai Node.js 22 LTS truoc." }

foreach ($p in @($py, (Join-Path $fe "server.js"))) {
    if (-not (Test-Path $p)) { throw "Thieu '$p'. Chay .\deploy\win\build.ps1 truoc." }
}
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Install-ArkonService {
    param(
        [string]$Name,
        [string]$Exe,
        [string]$Arguments,
        [string]$WorkDir,
        [string[]]$EnvExtra = @()
    )

    if (Get-Service -Name $Name -ErrorAction SilentlyContinue) {
        Write-Host "==> Go service cu: $Name"
        nssm stop   $Name confirm | Out-Null
        nssm remove $Name confirm | Out-Null
        Start-Sleep -Seconds 2
    }

    Write-Host "==> Cai service: $Name"
    nssm install $Name $Exe $Arguments          | Out-Null
    nssm set $Name AppDirectory  $WorkDir       | Out-Null
    nssm set $Name DisplayName   $Name          | Out-Null
    nssm set $Name Start         SERVICE_DELAYED_AUTO_START | Out-Null
    nssm set $Name AppStdout     (Join-Path $LogDir "$Name.out.log") | Out-Null
    nssm set $Name AppStderr     (Join-Path $LogDir "$Name.err.log") | Out-Null
    nssm set $Name AppRotateFiles 1             | Out-Null
    nssm set $Name AppRotateBytes 20971520      | Out-Null
    # Tu khoi dong lai khi crash, cho 5s giua cac lan
    nssm set $Name AppExit Default Restart      | Out-Null
    nssm set $Name AppRestartDelay 5000         | Out-Null
    # Dung mem: gui Ctrl+C truoc khi kill
    nssm set $Name AppStopMethodConsole 15000   | Out-Null

    if ($EnvExtra.Count -gt 0) {
        nssm set $Name AppEnvironmentExtra $EnvExtra | Out-Null
    }
    if ($ServiceUser) {
        Write-Host "    -> chay duoi tai khoan $ServiceUser"
        $cred = Get-Credential -UserName $ServiceUser -Message "Mat khau cho $ServiceUser"
        nssm set $Name ObjectName $ServiceUser $cred.GetNetworkCredential().Password | Out-Null
    }
}

# ---------------------------------------------------------------- API
Install-ArkonService -Name "Arkon-API" -Exe $py -WorkDir $ProjectRoot `
    -Arguments "-m uvicorn app.main:app --host 127.0.0.1 --port 5055 --proxy-headers --forwarded-allow-ips 127.0.0.1" `
    -EnvExtra @("PYTHONUNBUFFERED=1", "PYTHONIOENCODING=utf-8")

# ---------------------------------------------------------------- Workers
Install-ArkonService -Name "Arkon-Worker" -Exe $py -WorkDir $ProjectRoot `
    -Arguments "-m arq app.worker.WorkerSettings" `
    -EnvExtra @("PYTHONUNBUFFERED=1", "PYTHONIOENCODING=utf-8")

Install-ArkonService -Name "Arkon-Skills" -Exe $py -WorkDir $ProjectRoot `
    -Arguments "-m arq app.worker.SkillWorkerSettings" `
    -EnvExtra @("PYTHONUNBUFFERED=1", "PYTHONIOENCODING=utf-8")

# ---------------------------------------------------------------- Frontend
Install-ArkonService -Name "Arkon-Frontend" -Exe $node -WorkDir $fe `
    -Arguments "server.js" `
    -EnvExtra @("NODE_ENV=production", "PORT=3000", "HOSTNAME=127.0.0.1",
                "INTERNAL_API_URL=http://127.0.0.1:5055", "NEXT_TELEMETRY_DISABLED=1")

Write-Host ""
Write-Host "==> Khoi dong cac service"
foreach ($n in @("Arkon-API", "Arkon-Worker", "Arkon-Skills", "Arkon-Frontend")) {
    nssm start $n | Out-Null
}
Start-Sleep -Seconds 5
Get-Service Arkon-* | Format-Table Name, Status, StartType -AutoSize

Write-Host ""
Write-Host "Log service nam o: $LogDir"
Write-Host "Kiem tra nhanh:  curl.exe http://127.0.0.1:5055/health"
Write-Host "                 curl.exe -I http://127.0.0.1:3000/"
