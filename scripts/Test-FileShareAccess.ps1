<#
.SYNOPSIS
    Smoke test for the lab: checks DNS, port 445 and a Kerberos mount
    of the Azure file share from CLIENT01.

.DESCRIPTION
    Runs on CLIENT01 through Azure VM Run Command (as SYSTEM).
    SYSTEM authenticates to the share with the CLIENT01$ computer
    account, so a successful mount proves that the domain join,
    the storage account AD DS join, Kerberos and the default
    share-level permission all work. No storage key is used.

    Checks:
      1. The file endpoint resolves to the private endpoint (10.10.3.x)
      2. TCP 445 is reachable
      3. The share mounts without a key and a file can be written
      4. A Kerberos ticket for cifs/<account>.file.<suffix> was issued

.PARAMETER StorageAccountName
    Storage account name.

.PARAMETER ShareName
    File share name.

.PARAMETER StorageSuffix
    Storage DNS suffix.
#>

param(
    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [string]$ShareName = 'fileshare',

    [string]$StorageSuffix = 'core.windows.net'
)

$ErrorActionPreference = 'Stop'

$fqdn = "$StorageAccountName.file.$StorageSuffix"
$unc  = "\\$fqdn\$ShareName"
$failed = $false

function Write-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $status = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Output ("[{0}] {1}: {2}" -f $status, $Name, $Detail)
    if (-not $Ok) { $script:failed = $true }
}

# 1. DNS: must resolve to the private endpoint

$ip = (Resolve-DnsName $fqdn -Type A -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq 'A' }).IPAddress | Select-Object -First 1

Write-Check 'DNS' ($ip -like '10.10.3.*') "$fqdn -> $ip"

# 2. Port 445

$tcp = Test-NetConnection -ComputerName $fqdn -Port 445 -WarningAction SilentlyContinue
Write-Check 'TCP 445' $tcp.TcpTestSucceeded "$fqdn ($($tcp.RemoteAddress))"

# 3. Mount with Kerberos (no key) and write a file

klist purge -li 0x3e7 | Out-Null

$netUse = net use $unc 2>&1
$mounted = $LASTEXITCODE -eq 0
Write-Check 'Mount (Kerberos)' $mounted ($netUse | Out-String).Trim()

if ($mounted) {
    try {
        $file = Join-Path $unc "smoke-test-$env:COMPUTERNAME.txt"
        "Smoke test $(Get-Date -Format o)" | Set-Content -Path $file
        $content = Get-Content -Path $file
        Write-Check 'Write file' ($null -ne $content) $file
    }
    catch {
        Write-Check 'Write file' $false $_.Exception.Message
    }

    # 4. Kerberos ticket for the storage account SPN
    $tickets = klist -li 0x3e7 | Out-String
    Write-Check 'Kerberos ticket' ($tickets -match [regex]::Escape("cifs/$fqdn")) "cifs/$fqdn"

    net use $unc /delete /y | Out-Null
}

if ($failed) {
    throw 'One or more checks failed.'
}

Write-Output 'All checks passed.'
