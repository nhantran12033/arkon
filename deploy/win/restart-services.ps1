<#
  Arkon — Restart toan bo service sau khi deploy code moi.
  Chay bang PowerShell Administrator.

      cd C:\Storm12\Deployment\Arkon\arkon
      .\deploy\win\restart-services.ps1
#>

[CmdletBinding()]
param(
    [string]$LogDir = "C:\Logs\Arkon"
)

$ErrorActionPreference = "Stop"

# Dung nguoc thu tu phu thuoc, khoi dong lai theo thu tu xuoi
$stopOrder  = @("Arkon-Frontend", "Arkon-Skills", "Arkon-Worker", "Arkon-API")
$startOrder = @("Arkon-API", "Arkon-Worker", "Arkon-Skills", "Arkon-Frontend")

Write-Host "==> Dung service"
foreach ($s in $stopOrder) {
    if (Get-Service -Name $s -ErrorAction SilentlyContinue) {
        Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
        Write-Host "    stopped $s"
    }
}

Start-Sleep -Seconds 3

Write-Host "==> Khoi dong lai"
foreach ($s in $startOrder) {
    if (Get-Service -Name $s -ErrorAction SilentlyContinue) {
        Start-Service -Name $s
        Write-Host "    started $s"
    }
}

Start-Sleep -Seconds 5
Get-Service Arkon-* | Format-Table Name, Status, StartType -AutoSize

Write-Host ""
Write-Host "==> Health check"
curl.exe -s http://127.0.0.1:5055/health
Write-Host ""
Write-Host "Neu khong co phan hoi, xem $LogDir\Arkon-API.err.log"
