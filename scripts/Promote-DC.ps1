<#
.SYNOPSIS
    Promotes the VM to the first Domain Controller of a new AD DS forest.

.DESCRIPTION
    Non-interactive and idempotent:
      - If the server is already a Domain Controller, it exits successfully.
      - The DSRM password is received as a parameter (passed as a
        protected parameter by Run Command, never stored in the repo).
      - The reboot is scheduled a minute after the script ends, so
        Run Command can report success before Windows restarts.

.PARAMETER DomainName
    FQDN of the new forest root domain.

.PARAMETER NetBIOSName
    NetBIOS name of the new domain.

.PARAMETER DsrmPassword
    Directory Services Restore Mode password.

.PARAMETER RebootDelaySeconds
    Delay before the post-promotion restart.
#>

param(
    [string]$DomainName = 'lab.contoso.com',

    [string]$NetBIOSName = 'LAB',

    [Parameter(Mandatory)]
    [string]$DsrmPassword,

    [int]$RebootDelaySeconds = 60
)

$ErrorActionPreference = 'Stop'

# Skip if this server is already a Domain Controller
# DomainRole 4 = Backup DC, 5 = Primary DC
if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) {
    Write-Output "Server is already a Domain Controller for $((Get-CimInstance Win32_ComputerSystem).Domain). Nothing to do."
    exit 0
}

# Make sure the AD DS role is present
$feature = Get-WindowsFeature -Name AD-Domain-Services

if ($feature.InstallState -ne 'Installed') {
    throw 'AD DS role is not installed. Run Install-ADDS.ps1 first.'
}

Import-Module ADDSDeployment

$secureDsrm = ConvertTo-SecureString $DsrmPassword -AsPlainText -Force

Write-Output "Promoting server to Domain Controller for new forest '$DomainName' ($NetBIOSName)..."

$result = Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetBIOSName `
    -InstallDns `
    -SafeModeAdministratorPassword $secureDsrm `
    -NoRebootOnCompletion `
    -Force

Write-Output "Promotion status: $($result.Status)"

if ($result.Status -ne 'Success') {
    throw "Forest installation did not succeed: $($result.Message)"
}

# Schedule the restart instead of rebooting immediately,
# so the Run Command can return its result first
Write-Output "Restart scheduled in $RebootDelaySeconds seconds."

shutdown.exe /r /t $RebootDelaySeconds /c 'Restart after AD DS forest promotion' /d p:4:2
