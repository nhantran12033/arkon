<#
  Arkon — Cau hinh IIS (ARR + URL Rewrite) cho reverse proxy
  ===========================================================
  CHAY BANG POWERSHELL VOI QUYEN ADMINISTRATOR.

      cd D:\Storm12\Arkon\arkon
      .\deploy\win\configure-iis.ps1 -SiteName "Arkon" -HostName "arkon.congty.com"

  Script nay lam nhung viec ma UI hay bi quen:
    1. Bat ARR proxy
    2. Tang timeout proxy len 600s (LLM/ingest chay lau)
    3. Tat response buffering (bat buoc cho MCP streamable HTTP / SSE)
    4. Cho phep rewrite ghi de HTTP_X_FORWARDED_PROTO / HTTP_X_FORWARDED_HOST
    5. Tao app pool + site + copy web.config

  Neu chua cai module, cai truoc bang:
      winget install Microsoft.WebPlatformInstaller   # hoac tai truc tiep:
      # URL Rewrite 2.1 : https://www.iis.net/downloads/microsoft/url-rewrite
      # ARR 3.0         : https://www.iis.net/downloads/microsoft/application-request-routing
#>

[CmdletBinding()]
param(
    [string]$SiteName     = "Arkon",
    [Parameter(Mandatory = $true)][string]$HostName,
    [string]$PhysicalPath = "D:\inetpub\arkon",
    [string]$ProjectRoot  = (Resolve-Path "$PSScriptRoot\..\..")
)

$ErrorActionPreference = "Stop"
Import-Module WebAdministration

$appcmd = "$env:windir\system32\inetsrv\appcmd.exe"

# --- 1..3. Cau hinh ARR proxy ------------------------------------------------
# Ten thuoc tinh cua section system.webServer/proxy khac nhau giua cac ban ARR,
# nen dat tung cai trong try/catch. Cai nao bao FAIL thi vao IIS Manager chinh tay:
#   IIS Manager > (chon server) > Application Request Routing Cache
#     > Server Proxy Settings (panel ben phai)
function Set-ProxyProp {
    param([string]$Name, $Value, [string]$Note)
    try {
        Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
            -Filter 'system.webServer/proxy' -Name $Name -Value $Value -ErrorAction Stop
        Write-Host ("    OK   {0} = {1}   ({2})" -f $Name, $Value, $Note)
    } catch {
        Write-Warning ("    FAIL {0} — chinh tay trong Server Proxy Settings: {1}" -f $Name, $Note)
    }
}

Write-Host "==> Cau hinh ARR proxy"
Set-ProxyProp -Name "enabled"                 -Value $true       -Note "Enable proxy"
Set-ProxyProp -Name "timeout"                 -Value "00:10:00"  -Note "Time-out = 600s, cho LLM/ingest chay lau"
Set-ProxyProp -Name "responseBufferThreshold" -Value 0           -Note "Response buffer threshold (KB) = 0 — BAT BUOC cho MCP streaming/SSE"
Set-ProxyProp -Name "preserveHostHeader"      -Value $true       -Note "Preserve original HOST header"
Set-ProxyProp -Name "reverseRewriteHostInResponseHeaders" -Value $false -Note "Tat reverse rewrite host"

# --- 4. Cho phep ghi de server variable -------------------------------------
Write-Host "==> Cho phep rewrite dat X-Forwarded-*"
foreach ($v in @("HTTP_X_FORWARDED_PROTO", "HTTP_X_FORWARDED_HOST")) {
    & $appcmd set config -section:system.webServer/rewrite/allowedServerVariables "/+[name='$v']" /commit:apphost 2>$null | Out-Null
}

# --- 5. App pool + site -----------------------------------------------------
New-Item -ItemType Directory -Force -Path $PhysicalPath | Out-Null

if (-not (Test-Path "IIS:\AppPools\$SiteName")) {
    Write-Host "==> Tao app pool $SiteName"
    New-WebAppPool -Name $SiteName | Out-Null
}
# Site chi lam proxy — khong chay code .NET
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name managedRuntimeVersion -Value ""
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name startMode             -Value "AlwaysRunning"
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name processModel.idleTimeout -Value "00:00:00"
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name recycling.periodicRestart.time -Value "00:00:00"

if (-not (Test-Path "IIS:\Sites\$SiteName")) {
    Write-Host "==> Tao site $SiteName -> $PhysicalPath"
    New-Website -Name $SiteName -PhysicalPath $PhysicalPath -ApplicationPool $SiteName `
                -HostHeader $HostName -Port 80 | Out-Null
}

Write-Host "==> Copy web.config"
Copy-Item (Join-Path $ProjectRoot "deploy\iis\web.config") (Join-Path $PhysicalPath "web.config") -Force

Write-Host ""
Write-Host "==> XONG phan tu dong."
Write-Host "CON LAI LAM TAY TRONG IIS MANAGER:"
Write-Host "  1. Gan chung chi SSL: $SiteName -> Bindings -> Add https, port 443, host $HostName"
Write-Host "     (Neu chua bat SSL, hay xoa rule 'Force HTTPS' trong web.config)"
Write-Host "  2. Bat tinh nang 'WebSocket Protocol' trong Server Manager > Add Roles > Web Server > Application Development"
Write-Host "  3. Mo firewall port 80/443. KHONG mo 3000/5055/5433/6379/9002."
