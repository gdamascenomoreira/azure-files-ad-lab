<#
.SYNOPSIS
    Prepares CLIENT01 for testing and troubleshooting Azure Files
    with AD DS authentication.

.DESCRIPTION
    Runs on CLIENT01 through Azure VM Run Command, after the domain join.
    Non-interactive and idempotent.

    Steps:
      1. Waits until the computer is joined to the domain
      2. Adds the lab groups to the local Remote Desktop Users group,
         so the lab users can sign in through Azure Bastion
      3. Installs the Active Directory PowerShell module (RSAT)
      4. Installs AzFilesHybrid from the PowerShell Gallery for all users,
         with its dependencies (Az and Microsoft Graph modules).
         This provides Debug-AzStorageAccountAuth.

.PARAMETER RemoteDesktopGroups
    Comma-separated domain groups to add to Remote Desktop Users,
    e.g. 'LAB\FileShare-Users,LAB\FileShare-Admins'.

.PARAMETER TimeoutMinutes
    Maximum time to wait for the domain join and the group lookup.
#>

param(
    [string]$RemoteDesktopGroups = 'LAB\FileShare-Users,LAB\FileShare-Admins',

    [int]$TimeoutMinutes = 15
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

# 1. Wait for the domain join

while (-not (Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
    if ((Get-Date) -gt $deadline) {
        throw "Computer is not joined to a domain after $TimeoutMinutes minutes."
    }
    Write-Output 'Not joined to the domain yet. Retrying in 30 seconds...'
    Start-Sleep -Seconds 30
}

Write-Output "Joined to domain: $((Get-CimInstance Win32_ComputerSystem).Domain)"

# 2. Remote Desktop Users
#    Retries while the DC can't resolve the group yet (right after the join)

$groups = $RemoteDesktopGroups.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }

foreach ($group in $groups) {

    $members = (Get-LocalGroupMember -Group 'Remote Desktop Users').Name

    if ($members -contains $group) {
        Write-Output "Already in Remote Desktop Users: $group"
        continue
    }

    while ($true) {
        try {
            Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $group
            Write-Output "Added to Remote Desktop Users: $group"
            break
        }
        catch {
            if ((Get-Date) -gt $deadline) { throw }
            Write-Output "Could not add $group yet ($($_.Exception.Message)). Retrying in 30 seconds..."
            Start-Sleep -Seconds 30
        }
    }
}

# 3. Active Directory PowerShell module

if ((Get-WindowsFeature -Name RSAT-AD-PowerShell).InstallState -eq 'Installed') {
    Write-Output 'Active Directory PowerShell module already installed.'
}
else {
    Install-WindowsFeature -Name RSAT-AD-PowerShell | Out-Null
    Write-Output 'Installed Active Directory PowerShell module.'
}

# 4. AzFilesHybrid (and its Az / Microsoft Graph dependencies)

if (Get-Module -ListAvailable -Name AzFilesHybrid) {
    $version = (Get-Module -ListAvailable -Name AzFilesHybrid | Sort-Object Version -Descending | Select-Object -First 1).Version
    Write-Output "AzFilesHybrid already installed: $version"
}
else {
    Write-Output 'Installing NuGet provider...'
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope AllUsers -Force | Out-Null

    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    Write-Output 'Installing AzFilesHybrid and its dependencies (this takes a few minutes)...'
    Install-Module -Name AzFilesHybrid -Scope AllUsers -Force -AllowClobber

    $version = (Get-Module -ListAvailable -Name AzFilesHybrid | Sort-Object Version -Descending | Select-Object -First 1).Version
    Write-Output "Installed AzFilesHybrid: $version"
}

Write-Output 'CLIENT01 is ready. To troubleshoot, sign in as a lab user and run:'
Write-Output '  Connect-AzAccount -UseDeviceAuthentication'
Write-Output '  Debug-AzStorageAccountAuth -StorageAccountName <name> -ResourceGroupName <rg> -Verbose'
