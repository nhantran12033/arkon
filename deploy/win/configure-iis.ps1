<#
  Arkon — Cau hinh IIS (ARR + URL Rewrite) cho reverse proxy, binding HTTPS
  =========================================================================
  CHAY BANG POWERSHELL VOI QUYEN ADMINISTRATOR.

      cd C:\Storm12\Deployment\Arkon\arkon
      .\deploy\win\configure-iis.ps1 -CertSubject "192.168.200.52"

  Ket qua:
      https://192.168.200.52:44380   site "Arkon"        -> Next.js 3000 + FastAPI 5055
      https://192.168.200.52:44381   site "Arkon-Files"  -> MinIO 9002

  Script lam nhung viec ma lam tay hay bi quen:
    1. Bat ARR proxy
    2. Timeout proxy 600s (goi LLM / ingest chay lau)
    3. Tat response buffering (BAT BUOC cho MCP streamable HTTP / SSE)
    4. Giu nguyen HOST header (BAT BUOC cho presigned URL cua MinIO)
    5. Cho phep rewrite ghi de HTTP_X_FORWARDED_PROTO / HTTP_X_FORWARDED_HOST
    6. Tao chung chi tu ky (neu chua truyen -CertThumbprint)
    7. Tao app pool + 2 site + binding HTTPS + copy web.config
    8. Mo firewall cho 2 port

  Chua cai module thi cai truoc:
    URL Rewrite 2.1 : https://www.iis.net/downloads/microsoft/url-rewrite
    ARR 3.0         : https://www.iis.net/downloads/microsoft/application-request-routing
  (Cai URL Rewrite TRUOC, ARR SAU.)
#>

[CmdletBinding()]
param(
    [string]$SiteName          = "Arkon",
    [int]   $Port              = 44380,

    # Site proxy cho MinIO. Dat 0 de bo qua (chi dung khi portal chay HTTP).
    [string]$MinioSiteName     = "Arkon-Files",
    [int]   $MinioPort         = 44381,

    # Chung chi. De trong CertThumbprint -> tu tao self-signed cho CertSubject.
    [string]$CertThumbprint    = "",
    [string]$CertSubject       = "192.168.200.52",

    [string]$PhysicalPath      = "C:\inetpub\arkon",
    [string]$MinioPhysicalPath = "C:\inetpub\arkon-files",
    [string]$ProjectRoot       = (Resolve-Path "$PSScriptRoot\..\..")
)

$ErrorActionPreference = "Stop"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Script nay phai chay bang PowerShell Administrator."
}

Import-Module WebAdministration
$appcmd = "$env:windir\system32\inetsrv\appcmd.exe"

# --- 0. Kiem tra module da cai chua ----------------------------------------
$modules = & $appcmd list modules
if ($modules -notmatch "RewriteModule")           { throw "Chua cai URL Rewrite 2.1." }
if ($modules -notmatch "ApplicationRequestRouting") { throw "Chua cai ARR 3.0." }

# --- 1. Cau hinh ARR proxy --------------------------------------------------
# Ten thuoc tinh cua section system.webServer/proxy khac nhau giua cac ban ARR,
# nen dat tung cai trong try/catch. Cai nao FAIL thi chinh tay trong:
#   IIS Manager > (node server) > Application Request Routing Cache
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
Set-ProxyProp -Name "enabled"                 -Value $true      -Note "Enable proxy"
Set-ProxyProp -Name "timeout"                 -Value "00:10:00" -Note "Time-out = 600s"
Set-ProxyProp -Name "responseBufferThreshold" -Value 0          -Note "Response buffer threshold (KB) = 0 — BAT BUOC cho MCP/SSE"
Set-ProxyProp -Name "preserveHostHeader"      -Value $true      -Note "Preserve original HOST header — BAT BUOC cho MinIO presigned URL"
Set-ProxyProp -Name "reverseRewriteHostInResponseHeaders" -Value $false -Note "Tat reverse rewrite host"

# --- 2. Cho phep rewrite ghi de server variable ------------------------------
Write-Host "==> Cho phep rewrite dat X-Forwarded-*"
foreach ($v in @("HTTP_X_FORWARDED_PROTO", "HTTP_X_FORWARDED_HOST")) {
    & $appcmd set config -section:system.webServer/rewrite/allowedServerVariables "/+[name='$v']" /commit:apphost 2>$null | Out-Null
    Write-Host "    $v"
}

# --- 3. Chung chi -----------------------------------------------------------
if (-not $CertThumbprint) {
    $existing = Get-ChildItem Cert:\LocalMachine\My |
                Where-Object { $_.Subject -eq "CN=$CertSubject" -and $_.NotAfter -gt (Get-Date) } |
                Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($existing) {
        $CertThumbprint = $existing.Thumbprint
        Write-Host "==> Dung lai chung chi san co cho $CertSubject ($CertThumbprint)"
    } else {
        Write-Host "==> Tao chung chi tu ky cho $CertSubject"
        $cert = New-SelfSignedCertificate -DnsName $CertSubject, "localhost" `
                -CertStoreLocation "Cert:\LocalMachine\My" `
                -FriendlyName "Arkon ($CertSubject)" `
                -NotAfter (Get-Date).AddYears(3)
        $CertThumbprint = $cert.Thumbprint
        Write-Host "    Thumbprint: $CertThumbprint"
    }
}

# --- 4. Tao site ------------------------------------------------------------
function New-ArkonSite {
    param(
        [string]$Name,
        [int]$SitePort,
        [string]$Path,
        [string]$ConfigSource
    )

    New-Item -ItemType Directory -Force -Path $Path | Out-Null

    if (-not (Test-Path "IIS:\Sites\$Name")) {
        Write-Host "==> Tao site $Name  (port $SitePort -> $Path)"
        New-Website -Name $Name -PhysicalPath $Path -ApplicationPool $SiteName `
                    -Port $SitePort -Ssl | Out-Null
    } else {
        Write-Host "==> Site $Name da ton tai, cap nhat binding"
        Get-WebBinding -Name $Name | ForEach-Object {
            Remove-WebBinding -Name $Name -BindingInformation $_.bindingInformation -Protocol $_.protocol
        }
        New-WebBinding -Name $Name -Protocol https -Port $SitePort -IPAddress "*"
    }

    # Gan chung chi vao binding
    $ok = $false
    try {
        $b = Get-WebBinding -Name $Name -Protocol https
        $b.AddSslCertificate($CertThumbprint, "My")
        $ok = $true
    } catch { }
    if (-not $ok) {
        # Fallback: gan truc tiep bang netsh
        & netsh http delete sslcert ipport=0.0.0.0:$SitePort 2>$null | Out-Null
        & netsh http add sslcert ipport=0.0.0.0:$SitePort `
            certhash=$CertThumbprint appid="{00112233-4455-6677-8899-AABBCCDDEEFF}" certstorename=MY | Out-Null
    }
    Write-Host "    SSL cert da gan cho port $SitePort"

    Copy-Item $ConfigSource (Join-Path $Path "web.config") -Force
    Write-Host "    web.config: $ConfigSource -> $Path"
}

# App pool dung chung — site chi lam proxy, khong chay code .NET
if (-not (Test-Path "IIS:\AppPools\$SiteName")) {
    Write-Host "==> Tao app pool $SiteName"
    New-WebAppPool -Name $SiteName | Out-Null
}
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name managedRuntimeVersion          -Value ""
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name startMode                      -Value "AlwaysRunning"
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name processModel.idleTimeout       -Value "00:00:00"
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name recycling.periodicRestart.time -Value "00:00:00"

New-ArkonSite -Name $SiteName -SitePort $Port -Path $PhysicalPath `
              -ConfigSource (Join-Path $ProjectRoot "deploy\iis\web.config")

if ($MinioPort -gt 0) {
    New-ArkonSite -Name $MinioSiteName -SitePort $MinioPort -Path $MinioPhysicalPath `
                  -ConfigSource (Join-Path $ProjectRoot "deploy\iis\web.minio.config")
}

# --- 5. Firewall ------------------------------------------------------------
$ports = if ($MinioPort -gt 0) { @($Port, $MinioPort) } else { @($Port) }
Write-Host "==> Mo firewall port: $($ports -join ', ')"
Remove-NetFirewallRule -DisplayName "Arkon HTTPS" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Arkon HTTPS" -Direction Inbound `
                    -Protocol TCP -LocalPort $ports -Action Allow | Out-Null

# --- 6. Khoi dong -----------------------------------------------------------
Start-Website -Name $SiteName -ErrorAction SilentlyContinue
if ($MinioPort -gt 0) { Start-Website -Name $MinioSiteName -ErrorAction SilentlyContinue }

Get-Website | Where-Object { $_.Name -like "Arkon*" } | ForEach-Object {
    [PSCustomObject]@{
        Name     = $_.Name
        State    = $_.State
        Bindings = ($_.bindings.Collection | ForEach-Object { "$($_.protocol) $($_.bindingInformation)" }) -join ' | '
    }
} | Format-Table -AutoSize

Write-Host ""
Write-Host "==> XONG."
Write-Host "    Portal : https://$CertSubject`:$Port"
if ($MinioPort -gt 0) {
    Write-Host "    Files  : https://$CertSubject`:$MinioPort   (dat MINIO_PUBLIC_ENDPOINT=$CertSubject`:$MinioPort trong .env)"
}
Write-Host ""
Write-Host "    Chung chi tu ky -> trinh duyet se canh bao. Mo CA HAI dia chi mot lan"
Write-Host "    va bam qua canh bao, neu khong anh trong wiki se khong hien."
Write-Host "    Bat WebSocket Protocol neu chua bat:"
Write-Host "      Install-WindowsFeature Web-WebSockets"
