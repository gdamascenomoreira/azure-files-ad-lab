<#
.SYNOPSIS
    Smoke test for the lab: checks DNS, port 445 and a Kerberos mount
    of the Azure file share from CLIENT01.

.DESCRIPTION
    Runs on CLIENT01 through Azure VM Run Command.

    With -UserName and -Password, the share is mounted with that
    domain user (for example LAB\LabUser1). Azure Files only accepts
    AD DS identities over Kerberos (NTLM works only with the storage
    key), so a successful mount proves that the domain join, the storage
    account AD DS join, Kerberos and the user's share-level RBAC role work.

    Without credentials, the share is mounted as SYSTEM, which uses the
    CLIENT01$ computer account. That only works when a default share-level
    permission is set, because computer accounts can't get RBAC roles.

    Checks:
      1. The file endpoint resolves to the private endpoint (10.10.3.x)
      2. TCP 445 is reachable
      3. The share mounts without a storage key
      4. A file can be written and read
      5. A Kerberos ticket for cifs/<account>.file.<suffix> was issued

.PARAMETER StorageAccountName
    Storage account name.

.PARAMETER ShareName
    File share name.

.PARAMETER UserName
    Domain user to mount the share with, e.g. LAB\LabUser1.

.PARAMETER Password
    Password of the domain user.

.PARAMETER StorageSuffix
    Storage DNS suffix.
#>

param(
    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [string]$ShareName = 'fileshare',

    [string]$UserName,

    [string]$Password,

    [string]$StorageSuffix = 'core.windows.net'
)

$ErrorActionPreference = 'Stop'

$fqdn = "$StorageAccountName.file.$StorageSuffix"
$unc  = "\\$fqdn\$ShareName"
$identity = if ($UserName) { $UserName } else { "$env:COMPUTERNAME`$ (SYSTEM)" }
$failed = $false

function Write-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $status = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Output ("[{0}] {1}: {2}" -f $status, $Name, $Detail)
    if (-not $Ok) { $script:failed = $true }
}

Write-Output "Testing $unc as $identity"

# 1. DNS: must resolve to the private endpoint

$ip = (Resolve-DnsName $fqdn -Type A -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq 'A' }).IPAddress | Select-Object -First 1

Write-Check 'DNS' ($ip -like '10.10.3.*') "$fqdn -> $ip"

# 2. Port 445

$tcp = Test-NetConnection -ComputerName $fqdn -Port 445 -WarningAction SilentlyContinue
Write-Check 'TCP 445' $tcp.TcpTestSucceeded "$fqdn ($($tcp.RemoteAddress))"

# 3. Mount without a storage key

klist purge -li 0x3e7 | Out-Null
net use $unc /delete /y 2>&1 | Out-Null

if ($UserName) {
    $netUse = net use $unc $Password /user:$UserName /persistent:no 2>&1
}
else {
    $netUse = net use $unc /persistent:no 2>&1
}

$mounted = $LASTEXITCODE -eq 0
Write-Check 'Mount' $mounted ($netUse | Out-String).Trim()

if ($mounted) {

    # 4. Write and read a file
    try {
        $file = Join-Path $unc ("smoke-test-{0}.txt" -f ($identity -replace '[\\$ ()]', '_'))
        "Smoke test by $identity at $(Get-Date -Format o)" | Set-Content -Path $file
        $content = Get-Content -Path $file
        Write-Check 'Write file' ($null -ne $content) $file
    }
    catch {
        Write-Check 'Write file' $false $_.Exception.Message
    }

    # 5. Kerberos ticket for the storage account SPN
    $tickets = klist -li 0x3e7 | Out-String
    $hasTicket = $tickets -match [regex]::Escape("cifs/$fqdn")

    if ($hasTicket) {
        Write-Check 'Kerberos ticket' $true "cifs/$fqdn"
    }
    elseif ($UserName) {
        # Tickets for explicit credentials aren't always listed in the
        # SYSTEM cache; the mount itself already required Kerberos
        Write-Output "[INFO] Kerberos ticket: not listed in the SYSTEM cache (expected with explicit credentials). The mount required Kerberos."
    }
    else {
        Write-Check 'Kerberos ticket' $false "cifs/$fqdn not found"
    }

    net use $unc /delete /y | Out-Null
}
else {
    Write-Output ''
    Write-Output 'Hints:'
    Write-Output '  System error 5 (access denied): no share-level permission. Check the RBAC roles (Set-ShareRbac.ps1) or the default share permission. RBAC changes can take a few minutes to apply.'
    Write-Output '  System error 1326 / 86: wrong user name or password.'
    Write-Output '  System error 53 / 67: DNS or network. Check the DNS and TCP 445 results above.'
}

if ($failed) {
    throw 'One or more checks failed.'
}

Write-Output 'All checks passed.'
