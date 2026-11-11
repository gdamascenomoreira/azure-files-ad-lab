<#
.SYNOPSIS
    Sets the Windows ACLs (NTFS permissions) on the root of the Azure file share.

.DESCRIPTION
    Runs on CLIENT01 through Azure VM Run Command, during the deployment.
    Non-interactive and idempotent.

    The share is mounted with the storage account key, which is the
    administrative identity of Azure Files and bypasses both permission
    layers. The key is received as a protected parameter, used only for
    this connection, and the connection is removed at the end.

    Permissions on the share root (inherited by files and folders):
      FileShare-Users   Modify        (OI)(CI)M
      FileShare-Admins  Full Control  (OI)(CI)F

    The default entries of a new share (including Authenticated Users)
    are kept.

.PARAMETER StorageAccountName
    Storage account name.

.PARAMETER ShareName
    File share name.

.PARAMETER StorageKey
    Storage account key (protected parameter).

.PARAMETER UsersGroup
    Group that gets Modify.

.PARAMETER AdminsGroup
    Group that gets Full Control.

.PARAMETER StorageSuffix
    Storage DNS suffix.

.PARAMETER TimeoutMinutes
    Maximum time to retry while the share or the groups aren't reachable yet.
#>

param(
    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [string]$ShareName = 'fileshare',

    [Parameter(Mandatory)]
    [string]$StorageKey,

    [string]$UsersGroup = 'LAB\FileShare-Users',

    [string]$AdminsGroup = 'LAB\FileShare-Admins',

    [string]$StorageSuffix = 'core.windows.net',

    [int]$TimeoutMinutes = 15
)

# Native commands (net, icacls) report errors through $LASTEXITCODE.
# 'Stop' would turn their stderr output into terminating errors in
# Windows PowerShell 5.1.
$ErrorActionPreference = 'Continue'

$unc = "\\$StorageAccountName.file.$StorageSuffix\$ShareName"
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

# Runs a native command until it succeeds or the timeout is reached
function Invoke-WithRetry {
    param([string]$Description, [scriptblock]$Command)

    while ($true) {
        $output = & $Command 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            return $output
        }
        if ((Get-Date) -gt $deadline) {
            throw "$Description failed: $($output.Trim())"
        }
        # Write-Host so the message doesn't end up in the return value
        Write-Host "$Description failed (exit code $LASTEXITCODE). Retrying in 30 seconds..."
        Start-Sleep -Seconds 30
    }
}

Write-Output "Share: $unc"

# 1. Mount with the storage account key (administrative connection)

net use $unc /delete /y 2>&1 | Out-Null

Invoke-WithRetry 'Mount with storage account key' {
    net use $unc $StorageKey "/user:Azure\$StorageAccountName" /persistent:no
} | Out-Null

Write-Output 'Mounted with the storage account key.'

try {
    # 2. Grant the lab groups on the share root
    #    Retries while CLIENT01 can't resolve the domain groups yet

    Invoke-WithRetry "Grant $UsersGroup Modify" {
        icacls $unc /grant:r "${UsersGroup}:(OI)(CI)M"
    } | Out-Null
    Write-Output "Granted Modify: $UsersGroup"

    Invoke-WithRetry "Grant $AdminsGroup Full Control" {
        icacls $unc /grant:r "${AdminsGroup}:(OI)(CI)F"
    } | Out-Null
    Write-Output "Granted Full Control: $AdminsGroup"

    # 3. Show the result
    Write-Output ''
    Write-Output (icacls $unc | Out-String)
}
finally {
    # 4. Remove the administrative connection
    net use $unc /delete /y 2>&1 | Out-Null
    Write-Output 'Removed the storage account key connection.'
}

Write-Output 'Windows ACLs configured on the share root.'
