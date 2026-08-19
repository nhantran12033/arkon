<#
  Arkon — Restart toan bo service sau khi deploy code moi.
  Chay bang PowerShell Administrator.

      cd D:\Storm12\Arkon\arkon
      .\deploy\win\restart-services.ps1
#>

$ErrorActionPreference = "Stop"

$services = @("Arkon-Frontend", "Arkon-Skills", "Arkon-Worker", "Arkon-API")

Write-Host "==> Dung service (nguoc thu tu phu thuoc)"
foreach ($s in $services) {
    if (Get-Service -Name $s -ErrorAction SilentlyContinue) {
        Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
        Write-Host "    stopped $s"
    }
}

Start-Sleep -Seconds 3

Write-Host "==> Khoi dong lai"
foreach ($s in @("Arkon-API", "Arkon-Worker", "Arkon-Skills", "Arkon-Frontend")) {
    if (Get-Service -Name $s -ErrorAction SilentlyContinue) {
        Start-Service -Name $s
        Write-Host "    started $s"
    }
}

Start-Sleep -Seconds 5
Get-Service Arkon-* | Format-Table Name, Status, StartType -AutoSize

Write-Host ""
Write-Host "==> Health check"
try   { curl.exe -s http://127.0.0.1:5055/health }
catch { Write-Warning "API chua phan hoi — xem D:\Logs\Arkon\Arkon-API.err.log" }
