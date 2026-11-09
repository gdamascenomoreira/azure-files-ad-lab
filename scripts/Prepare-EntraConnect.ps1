<#
.SYNOPSIS
    Prepares DC01 for the Microsoft Entra Connect Sync installation.

.DESCRIPTION
    Runs on DC01 through Azure VM Run Command, after the AD configuration.
    Non-interactive and idempotent.

    Microsoft Entra Connect Sync itself can't be installed by this script:
    Microsoft supports the installation only through the wizard, and the
    .msi is only available from the Microsoft Entra admin center.
    This script does everything around it:

      1. Enables TLS 1.2 for .NET Framework (Entra Connect prerequisite)
      2. Turns off IE Enhanced Security Configuration for administrators,
         so the sign-in pages load inside the wizard
      3. Checks the prerequisites (OS, .NET, memory, disk, DC discovery,
         connectivity to Microsoft Entra ID) and fails if one is missing
      4. Places a shortcut on the public desktop that opens the
         Microsoft Entra Connect download page

.PARAMETER MinimumDotNetRelease
    Minimum .NET Framework release value (528040 = 4.8).
#>

param(
    [int]$MinimumDotNetRelease = 528040
)

$ErrorActionPreference = 'Stop'
$failed = $false

function Write-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $status = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Output ("[{0}] {1}: {2}" -f $status, $Name, $Detail)
    if (-not $Ok) { $script:failed = $true }
}

# 1. TLS 1.2 for .NET Framework

$netKeys = @(
    'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'
)

foreach ($key in $netKeys) {
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name 'SystemDefaultTlsVersions' -Value 1 -Type DWord
    Set-ItemProperty -Path $key -Name 'SchUseStrongCrypto' -Value 1 -Type DWord
}

$tlsBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2'

foreach ($side in 'Server', 'Client') {
    $key = "$tlsBase\$side"
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name 'Enabled' -Value 1 -Type DWord
    Set-ItemProperty -Path $key -Name 'DisabledByDefault' -Value 0 -Type DWord
}

Write-Output 'TLS 1.2 enabled for .NET Framework and SCHANNEL.'

# 2. IE Enhanced Security Configuration off for administrators

$esc = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}'

if (Test-Path $esc) {
    Set-ItemProperty -Path $esc -Name 'IsInstalled' -Value 0 -Type DWord
    Write-Output 'IE Enhanced Security Configuration turned off for administrators.'
}

# 3. Prerequisite checks

$os = Get-CimInstance Win32_OperatingSystem
Write-Check 'Operating system' ($os.Caption -match 'Server') "$($os.Caption) $($os.Version)"

$dotNet = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full').Release
Write-Check '.NET Framework' ($dotNet -ge $MinimumDotNetRelease) "Release $dotNet (minimum $MinimumDotNetRelease)"

$memoryGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
Write-Check 'Memory' ($memoryGb -ge 4) "$memoryGb GB (minimum 4 GB)"

$freeGb = [math]::Round((Get-Volume -DriveLetter C).SizeRemaining / 1GB, 1)
Write-Check 'Disk space' ($freeGb -ge 70) "$freeGb GB free on C: (minimum 70 GB)"

$domain = (Get-CimInstance Win32_ComputerSystem).Domain
$dc = nltest /dsgetdc:$domain 2>&1
Write-Check 'DC discovery' ($LASTEXITCODE -eq 0) "$domain"

foreach ($endpoint in 'login.microsoftonline.com', 'graph.microsoft.com') {
    $tcp = Test-NetConnection -ComputerName $endpoint -Port 443 -WarningAction SilentlyContinue
    Write-Check "Connectivity $endpoint" $tcp.TcpTestSucceeded "TCP 443 from $($tcp.SourceAddress.IPAddress)"
}

# 4. Desktop shortcut to the download pagea

$shortcut = 'C:\Users\Public\Desktop\Download Microsoft Entra Connect.url'

@(
    '[InternetShortcut]'
    'URL=https://entra.microsoft.com/#view/Microsoft_AAD_Connect_Provisioning/AADConnectMenuBlade/~/GetStarted'
) | Set-Content -Path $shortcut -Encoding ASCII

Write-Output "Shortcut created: $shortcut"

if ($failed) {
    throw 'One or more Microsoft Entra Connect prerequisites failed.'
}

Write-Output 'DC01 is ready for the Microsoft Entra Connect Sync installation.'
