<#
.SYNOPSIS
    Assigns share-level Azure RBAC roles to the AD DS groups synced to
    Microsoft Entra ID.

.DESCRIPTION
    Optional step, for when Microsoft Entra Connect Sync is running.
    Runs on your workstation with Azure CLI (az login first).

    Idempotent: existing role assignments are kept, missing ones are added.

    For each group it:
      1. Waits until the group is synced to Entra ID (onPremisesSyncEnabled)
      2. Fails if more than one synced group has the same name
         (leftovers from a previous lab forest)
      3. Assigns the role at the file share scope

    Default mapping:
      FileShare-Users   -> Storage File Data SMB Share Contributor
      FileShare-Admins  -> Storage File Data SMB Share Elevated Contributor

.PARAMETER ResourceGroupName
    Resource group of the lab.

.PARAMETER StorageAccountName
    Storage account name. If omitted, the only storage account in the
    resource group whose name starts with 'stfiles' is used.

.PARAMETER ShareName
    File share name.

.PARAMETER WaitMinutes
    Maximum time to wait for each group to appear in Entra ID.

.EXAMPLE
    ./scripts/Set-ShareRbac.ps1 -ResourceGroupName rg-fileslab
#>

param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [string]$StorageAccountName,

    [string]$ShareName = 'fileshare',

    [System.Collections.IDictionary]$GroupRoles = [ordered]@{
        'FileShare-Users'  = 'Storage File Data SMB Share Contributor'
        'FileShare-Admins' = 'Storage File Data SMB Share Elevated Contributor'
    },

    [int]$WaitMinutes = 40
)

$ErrorActionPreference = 'Stop'

# Runs an az command and returns its JSON output as objects
function Invoke-Az {
    $output = & az @args --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) {
        throw "az $($args -join ' ') failed."
    }
    if ($output) {
        # Assign first so Windows PowerShell 5.1 unrolls JSON arrays
        $result = $output | Out-String | ConvertFrom-Json
        $result
    }
}

# 1. Storage account and share scope

if (-not $StorageAccountName) {

    $accounts = @(Invoke-Az storage account list `
        --resource-group $ResourceGroupName `
        --query "[?starts_with(name, 'stfiles')].name")

    if ($accounts.Count -ne 1) {
        throw "Found $($accounts.Count) storage accounts starting with 'stfiles' in $ResourceGroupName. Use -StorageAccountName."
    }

    $StorageAccountName = $accounts[0]
}

$shareScope = (Invoke-Az storage share-rm show `
    --resource-group $ResourceGroupName `
    --storage-account $StorageAccountName `
    --name $ShareName).id

Write-Output "Share scope: $shareScope"

# 2. Groups and role assignments

foreach ($groupName in $GroupRoles.Keys) {

    $role = $GroupRoles[$groupName]

    # Wait for the synced group
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    $groups = @()

    while ($true) {

        $groups = @(Invoke-Az ad group list `
            --filter "displayName eq '$groupName'" `
            --query "[?onPremisesSyncEnabled].{id:id, created:createdDateTime, sid:onPremisesSecurityIdentifier}")

        if ($groups.Count -gt 0 -or (Get-Date) -gt $deadline) {
            break
        }

        Write-Output "Group '$groupName' not synced to Entra ID yet. Retrying in 60 seconds..."
        Start-Sleep -Seconds 60
    }

    if ($groups.Count -eq 0) {
        throw "Group '$groupName' was not synced within $WaitMinutes minutes. Check Entra Connect Sync (Start-ADSyncSyncCycle -PolicyType Delta on the sync server)."
    }

    if ($groups.Count -gt 1) {
        $list = ($groups | ForEach-Object { "  $($_.id)  created $($_.created)  SID $($_.sid)" }) -join "`n"
        throw "Found $($groups.Count) synced groups named '$groupName' (probably from a previous lab forest):`n$list`nDelete the old ones in Entra ID and run again."
    }

    $groupId = $groups[0].id

    # Assign the role if it isn't there yet
    $existing = @(Invoke-Az role assignment list `
        --assignee $groupId `
        --role $role `
        --scope $shareScope)

    if ($existing.Count -gt 0) {
        Write-Output "Already assigned: $groupName -> $role"
        continue
    }

    Invoke-Az role assignment create `
        --assignee-object-id $groupId `
        --assignee-principal-type Group `
        --role $role `
        --scope $shareScope | Out-Null

    Write-Output "Assigned: $groupName -> $role"
}

# 3. Summary

Invoke-Az role assignment list `
    --scope $shareScope `
    --query "[].{Principal:principalName, Role:roleDefinitionName}" |
    Format-Table -AutoSize
