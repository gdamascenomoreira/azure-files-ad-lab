<#
.SYNOPSIS
    Installs the AD DS role and management tools on the Domain Controller VM.

.DESCRIPTION
    Non-interactive and idempotent: if the role is already installed,
    the script exits successfully without changing anything.
    Designed to run through Azure VM Run Command.
#>

$ErrorActionPreference = 'Stop'

$feature = Get-WindowsFeature -Name AD-Domain-Services

if ($feature.InstallState -eq 'Installed') {
    Write-Output 'AD DS role already installed. Nothing to do.'
    exit 0
}

Write-Output 'Installing Active Directory Domain Services role...'

$result = Install-WindowsFeature `
    -Name AD-Domain-Services `
    -IncludeManagementTools

if (-not $result.Success) {
    throw 'AD DS role installation failed.'
}

Write-Output "AD DS role installed. Restart needed: $($result.RestartNeeded)"
