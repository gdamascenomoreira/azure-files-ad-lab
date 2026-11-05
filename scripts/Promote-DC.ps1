$ErrorActionPreference = 'Stop'

$DomainName = 'lab.contoso.com'
$NetBIOSName = 'LAB'

Import-Module ADDSDeployment

Write-Output "Preparing Active Directory forest installation..."

# Verify the AD DS role is installed
$feature = Get-WindowsFeature AD-Domain-Services

if ($feature.InstallState -ne 'Installed') {
    throw "AD DS role is not installed."
}

# Avoid promoting an existing Domain Controller again
if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) {
    throw "This server is already a Domain Controller."
}

# DSRM password must be supplied securely
$DSRMPassword = Read-Host `
    "Enter Directory Services Restore Mode password" `
    -AsSecureString

Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetBIOSName `
    -InstallDNS `
    -SafeModeAdministratorPassword $DSRMPassword `
    -NoRebootOnCompletion `
    -Force