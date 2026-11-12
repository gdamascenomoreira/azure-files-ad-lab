<#
.SYNOPSIS
    Assigns share-level Azure RBAC roles to the AD DS groups synced to
    Microsoft Entra ID.

.DESCRIPTION
    Runs after Microsoft Entra Connect Sync is installed on DC01.
    Runs on your workstation with Azure CLI (az login to the tenant
    that owns the subscription first).

    Idempotent: existing role assignments are kept, missing ones are added.

    For each group it:
      1. Reads the domain SID of the current lab forest from the storage
         account (set by the AD DS join)
      2. Waits until the group of THIS forest is synced to Entra ID:
         a synced group whose on-premises SID belongs to that domain.
         Groups with the same name left over from previous lab forests
         are ignored.
      3. Assigns the role at the file share scope:
           <storage-account-id>/fileServices/default/fileshares/<share>
      4. Removes the same role assigned by older versions of this script
         at the share's ARM resource ID (.../fileServices/default/shares/<share>)

    Scope: Azure RBAC accepts both paths, but Azure Files evaluates
    share-level roles only at .../fileshares/<share> (or above, on the
    storage account). A role at .../shares/<share> is listed, yet the mount
    fails with System error 5 (access denied on the SMB tree connect).
    That's why the scope isn't taken from 'az storage share-rm show'.

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

# The share must exist. Its ARM resource ID (.../shares/<share>) is the
# legacy scope: Azure Files doesn't evaluate share-level roles there.
$legacyScope = (Invoke-Az storage share-rm show `
    --resource-group $ResourceGroupName `
    --storage-account $StorageAccountName `
    --name $ShareName).id

$storageAccountId = Invoke-Az storage account show `
    --resource-group $ResourceGroupName `
    --name $StorageAccountName `
    --query id

# Scope evaluated by Azure Files for share-level permissions
$shareScope = "$storageAccountId/fileServices/default/fileshares/$ShareName"

Write-Output "Share scope: $shareScope"

# Domain SID of the current forest, from the storage account AD DS join.
# Used to pick this forest's groups and ignore leftovers of older labs.

$domainSid = Invoke-Az storage account show `
    --resource-group $ResourceGroupName `
    --name $StorageAccountName `
    --query 'azureFilesIdentityBasedAuthentication.activeDirectoryProperties.domainSid'

if (-not $domainSid) {
    throw "Storage account $StorageAccountName is not joined to AD DS (no domain SID). Check the join-storage-ad Run Command."
}

Write-Output "Lab domain SID: $domainSid"

# 2. Groups and role assignments

foreach ($groupName in $GroupRoles.Keys) {

    $role = $GroupRoles[$groupName]

    # Wait for the synced group
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    $groups = @()

    while ($true) {

        $synced = @(Invoke-Az ad group list `
            --filter "displayName eq '$groupName'" `
            --query "[?onPremisesSyncEnabled].{id:id, created:createdDateTime, sid:onPremisesSecurityIdentifier}")

        # Keep only the group of this forest
        $groups = @($synced | Where-Object { $_.sid -like "$domainSid-*" })

        $others = $synced.Count - $groups.Count
        if ($others -gt 0) {
            Write-Output "Ignoring $others synced '$groupName' group(s) from other forests."
        }

        if ($groups.Count -gt 0 -or (Get-Date) -gt $deadline) {
            break
        }

        Write-Output "Group '$groupName' of this forest not synced to Entra ID yet. Retrying in 60 seconds..."
        Start-Sleep -Seconds 60
    }

    if ($groups.Count -eq 0) {
        throw "Group '$groupName' was not synced within $WaitMinutes minutes. Check Entra Connect Sync (Start-ADSyncSyncCycle -PolicyType Delta on the sync server)."
    }

    if ($groups.Count -gt 1) {
        $list = ($groups | ForEach-Object { "  $($_.id)  created $($_.created)  SID $($_.sid)" }) -join "`n"
        throw "Found $($groups.Count) synced groups named '$groupName' with this forest's domain SID:`n$list"
    }

    $groupId = $groups[0].id
    Write-Output "Using group: $groupName ($groupId, SID $($groups[0].sid))"

    # Assign the role if it isn't there yet
    $existing = @(Invoke-Az role assignment list `
        --assignee $groupId `
        --role $role `
        --scope $shareScope)

    if ($existing.Count -gt 0) {
        Write-Output "Already assigned: $groupName -> $role"
    }
    else {
        Invoke-Az role assignment create `
            --assignee-object-id $groupId `
            --assignee-principal-type Group `
            --role $role `
            --scope $shareScope | Out-Null

        Write-Output "Assigned: $groupName -> $role"
    }

    # Remove the same role at the legacy scope (older versions of this script)
    $legacy = @(Invoke-Az role assignment list `
        --assignee $groupId `
        --role $role `
        --scope $legacyScope |
        Where-Object { $_.scope -eq $legacyScope })

    foreach ($assignment in $legacy) {
        Invoke-Az role assignment delete --ids $assignment.id | Out-Null
        Write-Output "Removed legacy assignment at .../shares/${ShareName}: $groupName -> $role"
    }
}

# 3. Summary

Invoke-Az role assignment list `
    --scope $shareScope `
    --query "[].{Principal:principalName, Role:roleDefinitionName}" |
    Format-Table -AutoSize
