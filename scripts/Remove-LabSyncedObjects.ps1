<#
.SYNOPSIS
    Removes the lab users and groups from Microsoft Entra ID before the
    lab is destroyed.

.DESCRIPTION
    Runs on DC01 through Azure VM Run Command, BEFORE deleting the
    resource group.

    Every deployment creates a new AD forest. If the old forest is
    destroyed while its objects are still synced, they stay in Entra ID
    as orphaned synced objects (they can't be edited or deleted while
    directory sync is on) and conflict with the next deployment
    (duplicate groups, UPN conflicts for the users).

    The script deletes the objects in the lab OUs in AD, plus the extra
    accounts listed in -AdditionalUsers (labadmin by default, which Express
    settings also sync), and runs a delta sync, so Entra Connect deletes
    them in Entra ID too.

    Deleting labadmin is safe here: the script runs as SYSTEM, the lab is
    about to be destroyed, and Entra Connect uses its own connector account.

    Deleted users stay in the Entra ID recycle bin for 30 days. Purge
    them afterwards (see the Quick Start, Clean up section).

    If Entra Connect isn't installed, the script does nothing.

.PARAMETER OrganizationalUnits
    OUs (names under the domain root) whose objects are removed.

.PARAMETER AdditionalUsers
    Accounts outside the lab OUs to delete as well (sAMAccountName).
    Use an empty string to skip.

.PARAMETER TimeoutMinutes
    Maximum time to wait for the sync cycle.
#>

param(
    [string[]]$OrganizationalUnits = @('LabUsers', 'LabGroups'),

    [string]$AdditionalUsers = 'labadmin',

    [int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'

$adSyncModule = 'C:\Program Files\Microsoft Azure AD Sync\Bin\ADSync\ADSync.psd1'

if (-not (Test-Path $adSyncModule)) {
    Write-Output 'Microsoft Entra Connect Sync is not installed on this server. Nothing to do.'
    exit 0
}

Import-Module ActiveDirectory
Import-Module $adSyncModule

function Wait-SyncIdle {
    param([datetime]$Deadline)

    while ((Get-ADSyncScheduler).SyncCycleInProgress) {
        if ((Get-Date) -gt $Deadline) {
            throw 'Timed out waiting for the sync cycle to finish.'
        }
        Write-Output 'Sync cycle in progress. Waiting 30 seconds...'
        Start-Sleep -Seconds 30
    }
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$domainDN = (Get-ADDomain).DistinguishedName

# 1. Delete the lab objects in AD

foreach ($ou in $OrganizationalUnits) {

    $ouDN = "OU=$ou,$domainDN"

    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'")) {
        Write-Output "OU not found, skipping: $ouDN"
        continue
    }

    $objects = @(Get-ADObject -SearchBase $ouDN -SearchScope OneLevel -Filter *)

    foreach ($object in $objects) {
        Remove-ADObject -Identity $object -Recursive -Confirm:$false
        Write-Output "Deleted in AD: $($object.Name) ($($object.ObjectClass))"
    }
}

# Accounts outside the lab OUs (synced with Express settings)

$extra = $AdditionalUsers.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }

foreach ($sam in $extra) {
    $user = Get-ADUser -Filter "SamAccountName -eq '$sam'"
    if ($user) {
        Remove-ADUser -Identity $user -Confirm:$false
        Write-Output "Deleted in AD: $sam (user)"
    }
    else {
        Write-Output "User not found, skipping: $sam"
    }
}

# 2. Delta sync, so the deletions are exported to Entra ID

Wait-SyncIdle -Deadline $deadline

$started = Get-Date
Start-ADSyncSyncCycle -PolicyType Delta | Out-Null
Write-Output 'Delta sync started.'

# Give the scheduler a moment to flag the cycle as running
Start-Sleep -Seconds 15
Wait-SyncIdle -Deadline $deadline

# 3. Results of the runs in this cycle

$results = Get-ADSyncRunProfileResult |
    Where-Object { $_.StartDate -ge $started.ToUniversalTime().AddMinutes(-1) }

$results |
    Sort-Object StartDate |
    Select-Object ConnectorName, RunProfileName, Result |
    Format-Table -AutoSize |
    Out-String |
    Write-Output

$errors = @($results | Where-Object { $_.Result -notin 'success', 'completed-no-objects' })

if ($errors) {
    throw 'The sync cycle reported errors. Check Synchronization Service Manager on DC01.'
}

Write-Output 'Lab objects deleted in AD and exported to Microsoft Entra ID.'
