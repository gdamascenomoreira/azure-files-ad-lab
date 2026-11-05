$ErrorActionPreference = 'Stop'

Import-Module ActiveDirectory

$domainDN = 'DC=lab,DC=contoso,DC=com'

$ous = @(
    'LabUsers',
    'LabGroups',
    'LabComputers'
)

foreach ($ou in $ous) {

    $existingOU = Get-ADOrganizationalUnit `
        -Filter "Name -eq '$ou'" `
        -SearchBase $domainDN

    if (-not $existingOU) {

        New-ADOrganizationalUnit `
            -Name $ou `
            -Path $domainDN

        Write-Output "Created OU: $ou"

    } else {

        Write-Output "OU already exists: $ou"
    }
}

$groups = @(
    'FileShare-Users',
    'FileShare-Admins'
)

foreach ($group in $groups) {

    if (-not (Get-ADGroup `
        -Filter "SamAccountName -eq '$group'" `
        -ErrorAction SilentlyContinue)) {

        New-ADGroup `
            -Name $group `
            -SamAccountName $group `
            -GroupScope Global `
            -GroupCategory Security `
            -Path "OU=LabGroups,$domainDN"

        Write-Output "Created group: $group"
    }
}

$verifiedDomain = Read-Host "Enter verified UPN suffix"

$password = Read-Host `
    "Enter temporary password for lab users" `
    -AsSecureString

$users = @(
    'LabUser1',
    'LabUser2'
)

foreach ($user in $users) {

    if (-not (Get-ADUser `
        -Filter "SamAccountName -eq '$user'" `
        -ErrorAction SilentlyContinue)) {

        New-ADUser `
            -Name $user `
            -SamAccountName $user `
            -UserPrincipalName "$user@$verifiedDomain" `
            -Path "OU=LabUsers,$domainDN" `
            -AccountPassword $password `
            -Enabled $true `
            -ChangePasswordAtLogon $false

        Write-Output "Created user: $user"
    }
}