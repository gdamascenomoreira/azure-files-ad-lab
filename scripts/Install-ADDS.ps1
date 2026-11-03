$ErrorActionPreference = 'Stop'

Write-Output "Installing Active Directory Domain Services..."

$result = Install-WindowsFeature `
    -Name AD-Domain-Services `
    -IncludeManagementTools

if (-not $result.Success) {
    throw "AD DS role installation failed."
}

Get-WindowsFeature AD-Domain-Services
