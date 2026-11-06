<#
.SYNOPSIS
    Configures the lab objects in Active Directory after the DC promotion.

.DESCRIPTION
    Non-interactive and idempotent. Every step checks the current state
    before changing anything, so the script can be run again safely.

    Steps:
      1. Waits until AD DS is available (first boot after promotion)
      2. Configures a DNS forwarder to Azure DNS (168.63.129.16)
      3. Adds the UPN suffix to the forest (when it differs from the domain)
      4. Creates the OUs
      5. Creates the security groups
      6. Creates the test users (or fixes their UPN if it changed)
      7. Adds the test users to FileShare-Users

.PARAMETER UpnSuffix
    UPN suffix for the lab users. Use your verified Microsoft Entra domain
    so synchronized users sign in with a routable UPN.
    Defaults to the AD DS domain name.

.PARAMETER UserPassword
    Password for the test users.

.PARAMETER TimeoutMinutes
    Maximum time to wait for AD DS to become available.
#>

param(
    [string]$UpnSuffix,

    [Parameter(Mandatory)]
    [string]$UserPassword,

    [string[]]$Users = @('LabUser1', 'LabUser2'),

    [int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'

# 1. Wait for AD DS (the DC may still be booting after promotion)

Write-Output 'Waiting for Active Directory Web Services...'

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$domain = $null

do {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $domain = Get-ADDomain -ErrorAction Stop
    }
    catch {
        Write-Output "AD DS not ready yet ($($_.Exception.Message)). Retrying in 30 seconds..."
        Start-Sleep -Seconds 30
    }
} until ($domain -or (Get-Date) -gt $deadline)

if (-not $domain) {
    throw "AD DS did not become available within $TimeoutMinutes minutes."
}

$domainDN  = $domain.DistinguishedName
$domainDns = $domain.DNSRoot

Write-Output "AD DS is available: $domainDns ($domainDN)"

if (-not $UpnSuffix) {
    $UpnSuffix = $domainDns
}

# 2. DNS forwarder to Azure DNS
#    Needed so the DC resolves privatelink.file.core.windows.net
#    (Azure Private DNS zone) to the Private Endpoint IP.

$azureDns = '168.63.129.16'
$forwarders = (Get-DnsServerForwarder).IPAddress.IPAddressToString

if ($forwarders -contains $azureDns) {
    Write-Output "DNS forwarder already set: $azureDns"
}
else {
    Set-DnsServerForwarder -IPAddress $azureDns
    Write-Output "Configured DNS forwarder: $azureDns"
}

# 3. UPN suffix

if ($UpnSuffix -ne $domainDns) {

    $forest = Get-ADForest

    if ($forest.UPNSuffixes -contains $UpnSuffix) {
        Write-Output "UPN suffix already present: $UpnSuffix"
    }
    else {
        Set-ADForest -Identity $forest.Name -UPNSuffixes @{ Add = $UpnSuffix }
        Write-Output "Added UPN suffix: $UpnSuffix"
    }
}

# 4. Organizational Units

$ous = @('LabUsers', 'LabGroups', 'LabComputers')

foreach ($ou in $ous) {

    $existingOU = Get-ADOrganizationalUnit `
        -Filter "Name -eq '$ou'" `
        -SearchBase $domainDN `
        -SearchScope OneLevel

    if ($existingOU) {
        Write-Output "OU already exists: $ou"
    }
    else {
        New-ADOrganizationalUnit -Name $ou -Path $domainDN
        Write-Output "Created OU: $ou"
    }
}

# 5. Security groups

$groups = @('FileShare-Users', 'FileShare-Admins')

foreach ($group in $groups) {

    if (Get-ADGroup -Filter "SamAccountName -eq '$group'") {
        Write-Output "Group already exists: $group"
    }
    else {
        New-ADGroup `
            -Name $group `
            -SamAccountName $group `
            -GroupScope Global `
            -GroupCategory Security `
            -Path "OU=LabGroups,$domainDN"

        Write-Output "Created group: $group"
    }
}

# 6. Test users

$securePassword = ConvertTo-SecureString $UserPassword -AsPlainText -Force

foreach ($user in $Users) {

    $upn = "$user@$UpnSuffix"
    $existingUser = Get-ADUser -Filter "SamAccountName -eq '$user'"

    if (-not $existingUser) {

        New-ADUser `
            -Name $user `
            -SamAccountName $user `
            -UserPrincipalName $upn `
            -Path "OU=LabUsers,$domainDN" `
            -AccountPassword $securePassword `
            -Enabled $true `
            -ChangePasswordAtLogon $false `
            -PasswordNeverExpires $true

        Write-Output "Created user: $upn"
    }
    elseif ($existingUser.UserPrincipalName -ne $upn) {

        Set-ADUser -Identity $existingUser -UserPrincipalName $upn
        Write-Output "Updated UPN: $($existingUser.UserPrincipalName) -> $upn"
    }
    else {
        Write-Output "User already exists: $upn"
    }
}

# 7. Group membership

$currentMembers = (Get-ADGroupMember -Identity 'FileShare-Users').SamAccountName
$missingMembers = $Users | Where-Object { $_ -notin $currentMembers }

if ($missingMembers) {
    Add-ADGroupMember -Identity 'FileShare-Users' -Members $missingMembers
    Write-Output "Added to FileShare-Users: $($missingMembers -join ', ')"
}
else {
    Write-Output 'FileShare-Users membership already correct.'
}

Write-Output 'Active Directory lab configuration completed.'
