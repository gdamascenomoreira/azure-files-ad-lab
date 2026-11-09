<#
.SYNOPSIS
    Registers the storage account in AD DS and enables AD DS
    authentication for Azure Files.

.DESCRIPTION
    Runs on the Domain Controller through Azure VM Run Command.
    Equivalent to Join-AzStorageAccountForAuth -DomainAccountType ComputerAccount,
    but without AzFilesHybrid or Az modules: it calls the Azure Resource Manager
    REST API with the VM's managed identity, so nothing is downloaded.

    Steps:
      1. Gets a token from the VM managed identity (IMDS)
      2. Skips everything if the storage account is already joined
         to this domain with the current computer account
      3. Regenerates the kerb1 key and reads it
      4. Creates (or updates) the computer account that represents the
         storage account: SPN cifs/<account>.file.<suffix>, AES-256,
         password = kerb1 key
      5. Enables AD DS authentication on the storage account and sets
         the default share-level permission

    If the account is already joined, only the default share-level
    permission is updated (when it changed).

    Requires the managed identity to have Storage Account Contributor
    on the storage account.

.PARAMETER StorageAccountId
    Resource ID of the storage account.

.PARAMETER OuPath
    Distinguished name of the OU for the computer account.

.PARAMETER ArmEndpoint
    Azure Resource Manager endpoint (environment().resourceManager).

.PARAMETER StorageSuffix
    Storage DNS suffix (environment().suffixes.storage), e.g. core.windows.net.

.PARAMETER DefaultSharePermission
    Share-level permission for every authenticated AD DS identity,
    including users that are not synced to Microsoft Entra ID.

.PARAMETER TimeoutMinutes
    Maximum time to wait for the managed identity role assignment to apply.
#>

param(
    [Parameter(Mandatory)]
    [string]$StorageAccountId,

    [Parameter(Mandatory)]
    [string]$OuPath,

    [string]$ArmEndpoint = 'https://management.azure.com/',

    [string]$StorageSuffix = 'core.windows.net',

    [ValidateSet(
        'None',
        'StorageFileDataSmbShareReader',
        'StorageFileDataSmbShareContributor',
        'StorageFileDataSmbShareElevatedContributor')]
    [string]$DefaultSharePermission = 'None',

    [int]$TimeoutMinutes = 15
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Import-Module ActiveDirectory

$apiVersion         = '2023-05-01'
$ArmEndpoint        = $ArmEndpoint.TrimEnd('/')
$storageAccountName = $StorageAccountId.Split('/')[-1]
$spn                = "cifs/$storageAccountName.file.$StorageSuffix"

if ($storageAccountName.Length -gt 15) {
    throw "Storage account name '$storageAccountName' is longer than 15 characters and cannot be used as an AD computer name."
}

# Helpers
# Messages inside functions use Write-Host so they don't end up in the return value.

# Token from the VM managed identity. Retries while the
# identity is still being provisioned on the VM.
function Get-ArmToken {
    $resource = [uri]::EscapeDataString("$ArmEndpoint/")
    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resource"

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            return (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' }).access_token
        }
        catch {
            Write-Host "Managed identity token not available yet ($($_.Exception.Message)). Retrying in 15 seconds..."
            Start-Sleep -Seconds 15
        }
    }

    throw 'Could not get a token from the VM managed identity.'
}

# Calls ARM and retries while the role assignment
# is still propagating (401/403).
function Invoke-Arm {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body
    )

    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $uri = "$ArmEndpoint$Path$($separator)api-version=$apiVersion"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    while ($true) {
        try {
            $request = @{
                Method  = $Method
                Uri     = $uri
                Headers = @{ Authorization = "Bearer $(Get-ArmToken)" }
            }

            if ($null -ne $Body) {
                $request.Body        = ($Body | ConvertTo-Json -Depth 10)
                $request.ContentType = 'application/json'
            }

            return Invoke-RestMethod @request
        }
        catch {
            $status = $null
            if ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }

            if ($status -in 401, 403 -and (Get-Date) -lt $deadline) {
                Write-Host "ARM $Method returned $status (role assignment may still be propagating). Retrying in 30 seconds..."
                Start-Sleep -Seconds 30
                continue
            }

            throw
        }
    }
}

# 1. Current state

$domain = Get-ADDomain
$forest = Get-ADForest

Write-Output "Domain: $($domain.DNSRoot) ($($domain.NetBIOSName))"
Write-Output "Storage account: $storageAccountName"

$account  = Invoke-Arm -Method Get -Path $StorageAccountId
$computer = Get-ADComputer -Filter "Name -eq '$storageAccountName'"
$adConfig = $account.properties.azureFilesIdentityBasedAuthentication

# 2. Already joined? Then only the default share permission may need an update

$alreadyJoined = $computer -and
    $adConfig.directoryServiceOptions -eq 'AD' -and
    $adConfig.activeDirectoryProperties.domainGuid -eq $domain.ObjectGUID.Guid -and
    $adConfig.activeDirectoryProperties.azureStorageSid -eq $computer.SID.Value

$currentPermission = if ($adConfig.defaultSharePermission) { $adConfig.defaultSharePermission } else { 'None' }

if ($alreadyJoined) {

    if ($currentPermission -eq $DefaultSharePermission) {
        Write-Output "Storage account is already joined to this domain (default share permission: $currentPermission). Nothing to do."
        exit 0
    }

    Write-Output "Storage account is already joined. Updating default share permission: $currentPermission -> $DefaultSharePermission"
}
else {

    # 3. Regenerate and read the kerb1 key

    Write-Output 'Regenerating kerb1 key...'

    Invoke-Arm -Method Post -Path "$StorageAccountId/regenerateKey" -Body @{ keyName = 'kerb1' } | Out-Null

    $keys = Invoke-Arm -Method Post -Path "$StorageAccountId/listKeys?`$expand=kerb"
    $kerb1 = ($keys.keys | Where-Object { $_.keyName -eq 'kerb1' }).value

    if (-not $kerb1) {
        throw 'Could not read the kerb1 key.'
    }

    $securePassword = ConvertTo-SecureString $kerb1 -AsPlainText -Force

    # 4. Computer account that represents the storage account

    if (-not $computer) {

        New-ADComputer `
            -Name $storageAccountName `
            -Path $OuPath `
            -Description "Azure Files storage account $storageAccountName" `
            -ServicePrincipalNames $spn `
            -KerberosEncryptionType AES256 `
            -AccountPassword $securePassword `
            -PasswordNeverExpires $true `
            -Enabled $true

        Write-Output "Created computer account: $storageAccountName in $OuPath"
    }
    else {

        Set-ADComputer `
            -Identity $computer `
            -ServicePrincipalNames @{ Replace = $spn } `
            -KerberosEncryptionType AES256

        Set-ADAccountPassword -Identity $computer -Reset -NewPassword $securePassword

        Write-Output "Updated computer account and password: $storageAccountName"
    }

}

$computer = Get-ADComputer -Identity $storageAccountName

# 5. Enable AD DS authentication and set the default share permission

Write-Output 'Configuring AD DS authentication on the storage account...'

$body = @{
    properties = @{
        azureFilesIdentityBasedAuthentication = @{
            directoryServiceOptions   = 'AD'
            defaultSharePermission    = $DefaultSharePermission
            activeDirectoryProperties = @{
                domainName        = $domain.DNSRoot
                netBiosDomainName = $domain.NetBIOSName
                forestName        = $forest.Name
                domainGuid        = $domain.ObjectGUID.Guid
                domainSid         = $domain.DomainSID.Value
                azureStorageSid   = $computer.SID.Value
                samAccountName    = $storageAccountName
                accountType       = 'Computer'
            }
        }
    }
}

$result = Invoke-Arm -Method Patch -Path $StorageAccountId -Body $body
$applied = $result.properties.azureFilesIdentityBasedAuthentication

Write-Output "Directory service: $($applied.directoryServiceOptions)"
Write-Output "Domain: $($applied.activeDirectoryProperties.domainName)"
Write-Output "Storage SID: $($applied.activeDirectoryProperties.azureStorageSid)"
Write-Output "Default share permission: $($applied.defaultSharePermission)"
Write-Output "SPN: $spn"
Write-Output 'Storage account AD DS configuration completed.'
