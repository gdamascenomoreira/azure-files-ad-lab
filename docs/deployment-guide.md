# Azure Files AD DS Lab - Deployment Guide

## 1. Introduction

This guide documents the deployment of an Azure Files lab
integrated with Active Directory Domain Services and
Microsoft Entra Connect Sync.

The environment simulates an on-premises Active Directory
infrastructure using Azure virtual machines.

## 2. Prerequisites

- Azure subscription
- Microsoft Entra tenant
- Visual Studio Code
- Git
- Azure CLI
- Bicep CLI
- PowerShell

## 3. Deployment Phases

## Phase 1 - Networking Deployment Results

### Deployment Information

- Resource Group: rg-fileslab
- Azure Region: North Europe
- Virtual Network: vnet-fileslab
- Address Space: 10.10.0.0/16
- Deployment Status: Succeeded
- Deployment Date: November 2, 2026

### Deployed Resources

| Resource | Name | Configuration |
|----------|------|---------------|
| Virtual Network | vnet-fileslab | 10.10.0.0/16 |
| NSG | vnet-fileslab-nsg | Default security rules |
| Subnet | snet-dc | 10.10.1.0/24 |
| Subnet | snet-client | 10.10.2.0/24 |
| Subnet | snet-private-endpoints | 10.10.3.0/24 |

### Validation Results

- [x] Virtual Network deployed successfully
- [x] Domain Controller subnet created
- [x] Client subnet created
- [x] Private Endpoint subnet created
- [x] Network Security Group created
- [x] Deployment provisioning state: Succeeded

### Issue Encountered

The initial deployment validation failed in West Europe.

Error:

RequestDisallowedByAzure:
The selected region is currently not accepting new customers.

### Resolution

Changed the deployment region from West Europe
to North Europe in main.bicepparam.

Repeated the deployment what-if operation.

The validation completed successfully, and the
networking infrastructure was deployed.

### Lessons Learned

- Bicep allows infrastructure to be deployed consistently.
- Azure regional restrictions may affect resource deployment.
- The what-if operation helps identify deployment issues.
- Resource Groups can exist in a different region from
  the resources deployed within them.

## Phase 2 - Active Directory

### Objective

Deploy a Windows Server virtual machine and configure it as the first Domain Controller for the lab.

The Domain Controller provides:

- Active Directory Domain Services
- DNS services
- Domain authentication
- Identity infrastructure for Microsoft Entra Connect Sync
- Identity infrastructure for Azure Files AD DS authentication

### Environment

| Component | Configuration |
|---|---|
| Azure VM | vm-dc01 |
| Computer name | DC01 |
| Operating system | Windows Server 2022 Datacenter |
| Azure region | North Europe |
| VM size | Standard_D2s_v5 |
| Virtual network | vnet-fileslab |
| Subnet | snet-dc |
| Private IP | 10.10.1.10 |
| Public IP | None |
| AD DS domain | lab.contoso.com |
| NetBIOS domain | LAB |
| Domain functional level | Windows2016Domain |
| Forest functional level | Windows2016Forest |
| Global Catalog | DC01.lab.contoso.com |

### Infrastructure Deployment

The Domain Controller infrastructure is defined in:

```text
modules/domainController.bicep
```

The module deploys:

- Windows Server virtual machine
- Azure network interface
- Static private IP reservation
- Managed operating system disk
- Connection to the Domain Controller subnet

The private IP address is configured as static on the Azure network interface:

```text
10.10.1.10
```

The Windows guest operating system continues to use DHCP. Azure reserves and supplies the private IP address to the VM.

### Secure Administrator Password

The administrator password is defined as a secure Bicep parameter:

```bicep
@secure()
param adminPassword string
```

The password is read from a local environment variable:

```bicep
param adminPassword = readEnvironmentVariable('FILESLAB_VM_PASSWORD')
```

The password is not stored in the public GitHub repository.

### Bicep Deployment

The Domain Controller deployment was previewed using:

```powershell
az deployment group what-if `
  --resource-group rg-fileslab `
  --template-file main.bicep `
  --parameters main.bicepparam
```

The infrastructure was deployed using:

```powershell
az deployment group create `
  --resource-group rg-fileslab `
  --template-file main.bicep `
  --parameters main.bicepparam
```

The deployment completed successfully.

### Domain Controller VM Validation

The VM status was validated using:

```powershell
az vm show `
  --resource-group rg-fileslab `
  --name vm-dc01 `
  --show-details `
  --output table
```

Result:

```text
VM name: vm-dc01
Power state: VM running
Region: northeurope
```

The network interface was validated using:

```powershell
az network nic show `
  --resource-group rg-fileslab `
  --name vm-dc01-nic `
  --query "ipConfigurations[].{Name:name,PrivateIP:privateIPAddress,Allocation:privateIPAllocationMethod}" `
  --output table
```

Result:

```text
Private IP: 10.10.1.10
Allocation: Static
```

### AD DS Role Installation

The Active Directory Domain Services role was installed using:

```text
scripts/Install-ADDS.ps1
```

The script was executed inside the VM through Azure VM Run Command:

```powershell
az vm run-command invoke `
  --resource-group rg-fileslab `
  --name vm-dc01 `
  --command-id RunPowerShellScript `
  --scripts "@scripts/Install-ADDS.ps1"
```

The installation was validated using:

```powershell
Get-WindowsFeature AD-Domain-Services
```

Result:

```text
Name                InstallState
----                ------------
AD-Domain-Services  Installed
```

### Active Directory Forest Deployment

The server was promoted using:

```text
scripts/Promote-DC.ps1
```

The script used `Install-ADDSForest` with the following configuration:

```text
Domain name: lab.contoso.com
NetBIOS name: LAB
DNS installation: Enabled
Automatic restart: Disabled
```

The promotion completed successfully:

```text
Status: Success
RebootRequired: True
```

DC01 was restarted after the promotion completed.

### Active Directory Validation

The domain was validated using:

```powershell
Get-ADDomain
```

Confirmed values:

```text
DNS root: lab.contoso.com
NetBIOS name: LAB
Domain mode: Windows2016Domain
PDC emulator: DC01.lab.contoso.com
Infrastructure master: DC01.lab.contoso.com
RID master: DC01.lab.contoso.com
```

The forest was validated using:

```powershell
Get-ADForest
```

Confirmed values:

```text
Forest name: lab.contoso.com
Forest mode: Windows2016Forest
Global Catalog: DC01.lab.contoso.com
Schema master: DC01.lab.contoso.com
Domain naming master: DC01.lab.contoso.com
```

The Domain Controller was validated using:

```powershell
Get-ADDomainController
```

Confirmed values:

```text
Domain Controller: DC01
FQDN: DC01.lab.contoso.com
IPv4 address: 10.10.1.10
Global Catalog: True
Read-only Domain Controller: False
LDAP port: 389
LDAPS port: 636
Operating system: Windows Server 2022 Datacenter
```

### Virtual Network DNS Configuration

The Azure virtual network is configured to use DC01 as its DNS server.

The following configuration was added to `modules/network.bicep`:

```bicep
dhcpOptions: {
  dnsServers: [
    '10.10.1.10'
  ]
}
```

The configuration was deployed successfully.

It was validated using:

```powershell
az network vnet show `
  --resource-group rg-fileslab `
  --name vnet-fileslab `
  --query "dhcpOptions.dnsServers" `
  --output json
```

Result:

```json
[
  "10.10.1.10"
]
```

### Domain Controller DNS Client

After promotion, the DC01 network adapter was configured to use the local DNS service:

```text
127.0.0.1
```

This is expected because DC01 hosts the DNS Server role locally.

The DNS client configuration was validated using Azure VM Run Command:

```powershell
az vm run-command invoke `
  --resource-group rg-fileslab `
  --name vm-dc01 `
  --command-id RunPowerShellScript `
  --scripts "hostname; Get-DnsClientServerAddress -AddressFamily IPv4"
```

Result:

```text
Host: DC01
Interface: Ethernet
DNS server: 127.0.0.1
```

The other virtual machines deployed in this virtual network will receive `10.10.1.10` as their DNS server.

### DNS Resolution Validation

The AD DS domain record was tested using:

```powershell
Resolve-DnsName lab.contoso.com -Server 127.0.0.1
```

Result:

```text
lab.contoso.com resolves to 10.10.1.10
```

The Domain Controller host record was tested using:

```powershell
Resolve-DnsName DC01.lab.contoso.com -Server 127.0.0.1
```

Result:

```text
DC01.lab.contoso.com resolves to 10.10.1.10
```

The DNS server also returned a link-local IPv6 record for DC01:

```text
fe80::573c:e1e8:7de8:efa2
```

External DNS resolution was tested using:

```powershell
Resolve-DnsName microsoft.com -Server 127.0.0.1
```

The query returned valid IPv4 and IPv6 addresses.

This confirms that:

- The DNS Server service is operational.
- The AD DS domain resolves internally.
- DC01 resolves to its expected private IPv4 address.
- External DNS resolution works.
- The virtual network is configured to direct domain members to DC01 for DNS.

### Troubleshooting

#### Issue 1: Missing Bicep Parameter Assignment

The Domain Controller deployment preview initially failed with:

```text
BCP258:
The following parameters are declared in the Bicep file
but are missing an assignment in the params file:
adminPassword
```

Resolution:

The password parameter was assigned through an environment variable in `main.bicepparam`:

```bicep
param adminPassword = readEnvironmentVariable('FILESLAB_VM_PASSWORD')
```

This allowed the password to remain outside the repository.

#### Issue 2: Unexpected Subnet Modifications

The deployment preview initially showed the following subnet modification:

```text
privateEndpointNetworkPolicies:
Disabled => Enabled
```

Resolution:

The intended policy state was explicitly added to the subnet resources:

```bicep
privateEndpointNetworkPolicies: 'Disabled'
```

A new what-if operation confirmed that the subnets would remain unchanged.

#### Issue 3: Install-WindowsFeature Not Recognized Locally

The following error occurred:

```text
Install-WindowsFeature is not recognized as a cmdlet.
```

Cause:

The Windows Server command was initially executed in the local development workstation's PowerShell session instead of inside DC01.

Resolution:

The installation script was executed inside DC01 through Azure VM Run Command.

#### Issue 4: ServerManager and ADDSDeployment Modules Not Found

The following errors occurred in the initial interactive PowerShell session:

```text
Get-WindowsFeature is not recognized as a cmdlet.
```

```text
The specified module 'ADDSDeployment' was not loaded
because no valid module file was found.
```

DISM confirmed that the relevant Windows features were enabled, including:

```text
ActiveDirectory-PowerShell
DirectoryServices-DomainController
RSAT-AD-Tools-Feature
RSAT-ADDS-Tools-Feature
DirectoryServices-DomainController-Tools
```

The promotion script was later executed successfully from a working Windows PowerShell session.

#### Issue 5: Static IP Warning During Promotion

Windows displayed a warning that the physical network adapter did not have a static address assigned in its IP properties.

Explanation:

The Windows guest uses DHCP, while Azure reserves `10.10.1.10` as a static private IP on the network interface.

No manual static IPv4 configuration was applied inside Windows.

#### Issue 6: DNS Delegation Warning

The promotion reported that a DNS delegation could not be created because the authoritative parent zone was unavailable.

Explanation:

`lab.contoso.com` is an isolated lab forest. It is not delegated from an existing `contoso.com` DNS zone.

No parent-zone delegation is required for this isolated lab scenario.

#### Issue 7: Cryptography Compatibility Warning

Windows Server 2022 reported that weaker cryptographic algorithms compatible with Windows NT 4.0 are blocked by default.

Resolution:

No changes were made. The safer Windows Server 2022 default was preserved.

#### Issue 8: Bastion Domain Authentication

The first Azure Bastion attempt after promotion returned:

```text
Connection Error:
Log in failed. Please reconnect and try again.
```

The Domain Controller was later accessed successfully.

For domain authentication through Azure Bastion, the domain account must be entered in UPN format:

```text
labadmin@lab.contoso.com
```

The DSRM password must not be used for a normal domain sign-in.

#### Issue 9 - DFS Replication Warning After Domain Controller Promotion

During the initial Domain Controller validation, the following
command reported a failure:

```powershell
dcdiag /q
```

Result:

```text
There are warning or error events within the last
24 hours after the SYSVOL has been shared.

DC01 failed test DFSREvent.
```

### Investigation

The DFS Replication service was checked:

```powershell
Get-Service DFSR
```

Result:

```text
Status: Running
Service: DFSR
```

The DFS Replication event log contained the following events:

| Event ID | Level | Description |
|---|---|---|
| 1202 | Error | DFSR could not initially contact a Domain Controller |
| 6016 | Warning | DFSR could not initially update its AD DS configuration |
| 4602 | Information | SYSVOL initialized successfully |
| 1206 | Information | DFSR successfully contacted DC01 |
| 1210 | Information | DFSR successfully configured its RPC listener |

The Event 1202 and Event 6016 entries returned:

```text
Error 1355:
The specified domain either does not exist
or could not be contacted.
```

These events occurred during the initial Active Directory
configuration and Domain Controller promotion.

The subsequent Event 4602 confirmed:

```text
The DFS Replication service successfully initialized
the SYSVOL replicated folder.

This member is the designated primary member for
this replicated folder.

No user action is required.
```

### SYSVOL Replication State

The current DFSR state was checked using:

```powershell
Get-CimInstance `
  -Namespace root\MicrosoftDFS `
  -ClassName DfsrReplicatedFolderInfo |
  Select-Object ReplicatedFolderName,State
```

Result:

```text
ReplicatedFolderName: SYSVOL Share
State: 4
```

State `4` indicates that the replicated folder is operating normally.

### Check for New DFSR Warnings or Errors

The DFS Replication event log was queried for warnings or
errors generated after the most recent successful initialization:

```powershell
Get-WinEvent `
  -FilterHashtable @{
    LogName = 'DFS Replication'
    Level = 2,3
    StartTime = [datetime]'2026-11-02 17:25:48'
  } `
  -ErrorAction SilentlyContinue |
  Select-Object TimeCreated,Id,LevelDisplayName,Message
```

Result:

```text
No events returned.
```

No new DFS Replication warnings or errors were recorded after
the successful initialization events.

### SYSVOL Health Validation

The following diagnostic was executed:

```powershell
dcdiag /test:SysVolCheck
```

Result:

```text
DC01 passed test Connectivity.
DC01 passed test SysVolCheck.
```

The required shares were also verified using:

```powershell
net share
```

Result:

```text
NETLOGON
SYSVOL
```

### LDAP and Domain Controller Discovery

The LDAP SRV record was resolved successfully:

```powershell
Resolve-DnsName `
  _ldap._tcp.dc._msdcs.lab.contoso.com `
  -Type SRV `
  -Server 127.0.0.1
```

Result:

```text
Target: dc01.lab.contoso.com
Port: 389
IPv4 address: 10.10.1.10
```

Domain Controller discovery was validated using:

```powershell
nltest /dsgetdc:lab.contoso.com
```

Result:

```text
Domain Controller: DC01.lab.contoso.com
Address: 10.10.1.10
Domain: lab.contoso.com
Forest: lab.contoso.com
Site: Default-First-Site-Name
```

The returned flags confirmed that DC01 provides:

- Primary Domain Controller services
- Global Catalog services
- LDAP
- Kerberos Key Distribution Center services
- Time services
- Writable directory services
- DNS services

### Assessment

The DFSREvent diagnostic detected historical errors generated
while the new forest and SYSVOL were being initialized.

Current evidence confirms:

- The DFS Replication service is running.
- SYSVOL initialization completed successfully.
- The SYSVOL replicated folder is in state `4`, Normal.
- No new DFSR warnings or errors were detected.
- DC01 passed the DCDIAG connectivity test.
- DC01 passed the DCDIAG SYSVOL test.
- SYSVOL and NETLOGON are shared.
- LDAP SRV records resolve correctly.
- Domain Controller discovery works.
- Internal and external DNS resolution works.

No DFS Replication recovery or SYSVOL restore action was required.

### Resolution

The earlier DFSREvent result was classified as a historical
initialization warning.

The current DFS Replication and SYSVOL state is healthy.

Status: Resolved.

### Phase 2 Validation Checklist

- [x] Domain Controller VM deployed
- [x] Static Azure private IP configured as 10.10.1.10
- [x] AD DS role installed
- [x] AD DS forest created
- [x] Domain Controller promoted
- [x] Domain Controller restarted
- [x] Active Directory domain validated
- [x] Active Directory forest validated
- [x] Global Catalog validated
- [x] Domain Controller IPv4 address validated
- [x] VNet DNS configured as 10.10.1.10
- [x] DC01 DNS client configuration validated
- [x] Internal AD DNS resolution validated
- [x] External DNS resolution validated
- [x] LDAP SRV records validated
- [x] Domain Controller discovery validated
- [x] DFS Replication service validated
- [x] SYSVOL replication state validated as Normal
- [x] No new DFSR warnings or errors detected
- [x] DCDIAG connectivity test passed
- [x] DCDIAG SYSVOL test passed
- [x] SYSVOL share validated
- [x] NETLOGON share validated

## Phase 3 - Microsoft Entra Connect Sync

### 3.1 Objective

Configure Microsoft Entra Connect Sync to synchronize identities
from the lab Active Directory forest to Microsoft Entra ID.

The synchronization infrastructure will support future Azure Files
authentication and authorization testing.

The environment uses:

- Active Directory Domain Services
- Microsoft Entra Connect Sync
- Password Hash Synchronization
- Microsoft Entra ID
- Synchronized users and security groups

### 3.2 Architecture

The Microsoft Entra Connect Sync service is installed directly
on the existing Domain Controller.

```text
Azure Subscription
│
└── Resource Group: rg-fileslab
    │
    └── vm-dc01 (10.10.1.10)
        │
        ├── Windows Server 2022
        ├── Active Directory Domain Services
        ├── DNS Server
        ├── Microsoft Entra Connect Sync
        │
        └── Active Directory Forest
            │
            └── lab.contoso.com
                │
                ├── LabUsers
                │   ├── LabUser1
                │   └── LabUser2
                │
                ├── LabGroups
                │   ├── FileShare-Users
                │   └── FileShare-Admins
                │
                └── LabComputers

Microsoft Entra Connect Sync
            │
            │ Password Hash Synchronization
            ▼
Microsoft Entra ID
            │
            ├── Synchronized Users
            └── Synchronized Security Groups
```

### 3.3 Architecture Decision

Initially, a separate member server was considered for
Microsoft Entra Connect Sync.

The proposed architecture included:

- DC01: Active Directory Domain Services and DNS
- SYNC01: Microsoft Entra Connect Sync
- CLIENT01: Domain-joined Windows client

However, the additional synchronization server was removed
from the design.

#### Reason

The primary objective of this project is to create a lightweight,
reusable Azure Files troubleshooting environment.

Deploying an additional synchronization server would increase:

- Infrastructure costs
- Resource consumption
- Deployment complexity
- Maintenance requirements

For this isolated lab, Microsoft Entra Connect Sync was installed
directly on DC01.

This preserves the identity synchronization functionality
required for Azure Files testing without introducing another VM.

#### Security Consideration

A dedicated Microsoft Entra Connect Sync server is generally
preferable in production environments.

Installing Microsoft Entra Connect on a Domain Controller
combines sensitive identity infrastructure components.

This design is intended for an isolated testing environment
and should not be considered a production recommendation.

### 3.4 Microsoft Entra Tenant

The Azure subscription was verified using:

```powershell
az account show `
  --query "{Subscription:name,TenantId:tenantId}" `
  --output table
```

Result:

```text
Subscription: Visual Studio Enterprise Subscription
Tenant ID: xxxxxxxxxxxxxxxxxxxx
```

This tenant was selected for the lab.

### 3.5 Active Directory UPN Configuration

The Active Directory forest uses:

```text
lab.contoso.com
```

The configured UPN suffixes were verified using:

```powershell
Get-ADForest |
  Select-Object -ExpandProperty UPNSuffixes
```

Result:

```text
lab.contoso.com
```

During configuration, an example placeholder was accidentally
added as an alternate UPN suffix.

The incorrect suffix was removed using:

```powershell
Set-ADForest `
  -Identity lab.contoso.com `
  -UPNSuffixes @{Remove='<verified-domain>'}
```

The forest configuration was subsequently verified.

Note:

The Active Directory domain name does not automatically
represent a verified Microsoft Entra domain.

The effective UPNs of synchronized users must be validated
in Microsoft Entra ID.

### 3.6 Active Directory Organizational Units

The following Organizational Units were created:

```text
OU=LabUsers,DC=lab,DC=contoso,DC=com

OU=LabGroups,DC=lab,DC=contoso,DC=com

OU=LabComputers,DC=lab,DC=contoso,DC=com
```

The configuration was automated using:

```text
scripts/Configure-ADLab.ps1
```

#### Initial Error

The first execution failed with:

```text
Get-ADOrganizationalUnit:
Directory object not found.
```

The script originally attempted to locate nonexistent OUs
using the Identity parameter.

Example:

```powershell
Get-ADOrganizationalUnit -Identity $dn
```

When the OU did not exist, the command generated an
ADIdentityNotFoundException.

#### Resolution

The script was modified to check for existing OUs using
the Filter parameter.

```powershell
$existingOU = Get-ADOrganizationalUnit `
    -Filter "Name -eq '$ou'" `
    -SearchBase $domainDN
```

If the OU does not exist, the script creates it.

The corrected script executed successfully:

```text
Created OU: LabUsers
Created OU: LabGroups
Created OU: LabComputers
```

A subsequent execution confirmed that the script could
identify existing objects:

```text
OU already exists: LabUsers
OU already exists: LabGroups
OU already exists: LabComputers
```

### 3.7 Active Directory Security Groups

Two security groups were created:

| Group | Purpose |
|---|---|
| FileShare-Users | Standard Azure Files access testing |
| FileShare-Admins | Administrative access testing |

Both groups were configured as Global Security groups.

The configuration script confirmed:

```text
Created group: FileShare-Users
Created group: FileShare-Admins
```

These groups will be used during Azure Files share-level
RBAC and NTFS permissions testing.

### 3.8 Active Directory Test Users

Two test users were created:

```text
LabUser1
LabUser2
```

Both users belong to:

```text
OU=LabUsers,DC=lab,DC=contoso,DC=com
```

Passwords were configured during account creation.

No passwords are stored in this repository.

### 3.9 Security Group Membership

The test users were added to the FileShare-Users group:

```powershell
Add-ADGroupMember `
  -Identity 'FileShare-Users' `
  -Members LabUser1,LabUser2
```

Membership was validated using:

```powershell
Get-ADGroupMember `
  -Identity 'FileShare-Users'
```

Result:

```text
LabUser1
LabUser2
```

Both users were successfully added.

### 3.10 Microsoft Entra Connect Prerequisites

The following checks were performed on DC01.

#### Operating System

```powershell
Get-CimInstance Win32_OperatingSystem |
  Select-Object Caption,Version,OSArchitecture
```

Result:

```text
Operating System: Windows Server 2022 Datacenter
Version: 10.0.20348
Architecture: 64-bit
```

#### .NET Framework

```powershell
Get-ItemProperty `
  'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' |
  Select-Object Release
```

Result:

```text
Release: 528449
```

#### Physical Memory

```powershell
Get-CimInstance Win32_ComputerSystem |
  Select-Object TotalPhysicalMemory
```

Result:

```text
8584425472 bytes
```

Approximately 8 GiB of RAM.

#### Internet Connectivity

```powershell
Test-NetConnection login.microsoftonline.com -Port 443
```

Result:

```text
Source IP: 10.10.1.10
Remote Port: 443
TcpTestSucceeded: True
```

#### Domain Controller Discovery

```powershell
nltest /dsgetdc:lab.contoso.com
```

Result:

```text
Domain Controller: DC01.lab.contoso.com
IP Address: 10.10.1.10
Domain: lab.contoso.com
```

#### Available Disk Space

```powershell
Get-Volume -DriveLetter C |
  Select-Object DriveLetter,SizeRemaining
```

Result:

```text
Approximately 120 GB available
```

The prerequisite checks did not identify a blocking issue.

### 3.11 Microsoft Entra Connect Installation

Microsoft Entra Connect Sync was downloaded through
the Microsoft Entra administration portal.

The installer was executed on DC01.

#### Installation Method

Express Settings were selected.

#### Reason

Express Settings simplified the installation and avoided
unnecessary configuration for the isolated lab.

The environment contains a single Active Directory forest
created specifically for testing.

#### Configuration

- Installation type: Express Settings
- Source forest: lab.contoso.com
- Sign-in method: Password Hash Synchronization
- OU filtering: Not configured
- Synchronization server: DC01
- Source anchor: mS-DS-ConsistencyGuid

Because Express Settings were used, synchronization
was not restricted to the LabUsers and LabGroups OUs.

The default synchronization scope was accepted.

### 3.12 Administrative Permissions

The installation required appropriate administrative
permissions in Microsoft Entra ID and Active Directory.

The Microsoft Entra account used for installation
had the following directory roles:

- Global Administrator
- Hybrid Identity Administrator

The installation was performed using an appropriately
privileged Active Directory administrator account.

Administrator passwords are intentionally excluded
from this documentation.

### 3.13 Installation Results

The Microsoft Entra Connect installer displayed:

```text
Configuration complete

Microsoft Entra Connect Sync configuration succeeded.

The synchronization process has been initiated.
```

The installation completed successfully.

The installer also displayed the following recommendations:

1. Enable Active Directory Recycle Bin.
2. Configure TPM to improve server security.
3. Use mS-DS-ConsistencyGuid as the source anchor.

The source anchor was configured automatically.

The Recycle Bin and TPM recommendations did not prevent
the installation from completing.

### 3.14 Synchronization Service Validation

The ADSync service was validated using:

```powershell
Get-Service ADSync
```

Result:

```text
Status: Running
Name: ADSync
Display Name: Microsoft Azure AD Sync
```

This confirmed that the synchronization service
was installed and running.

### 3.15 Troubleshooting - ADSync Module Not Found

During the initial validation, the following command failed:

```powershell
Import-Module ADSync
```

Error:

```text
The specified module 'ADSync' was not loaded because
no valid module file was found in any module directory.
```

#### Investigation

The ADSync module was located using:

```powershell
Get-ChildItem `
  "C:\Program Files\Microsoft Azure AD Sync" `
  -Filter "ADSync.psd1" `
  -Recurse |
  Select-Object FullName
```

Result:

```text
C:\Program Files\Microsoft Azure AD Sync\Bin\ADSync\ADSync.psd1
```

An attempt to import the module using an incorrect
Program Files path failed.

A subsequent import using the correct path returned:

```text
BadImageFormatException

An attempt was made to load a program
with an incorrect format.
```

#### Root Cause

The PowerShell architecture was identified as the
likely cause.

The ADSync module requires a compatible 64-bit
PowerShell execution environment.

#### Resolution

The PowerShell process architecture was verified using:

```powershell
:Is64BitProcess
```

Result:

```text
True
```

The ADSync module was then imported successfully:

```powershell
Import-Module ADSync
```

The synchronization scheduler cmdlets became available.

No Microsoft Entra Connect reinstallation was required.

### 3.16 Synchronization Scheduler Validation

The scheduler was validated using:

```powershell
Get-ADSyncScheduler
```

Results:

```text
AllowedSyncCycleInterval: 00:30:00

CurrentlyEffectiveSyncCycleInterval: 00:30:00

NextSyncCyclePolicyType: Delta

SyncCycleEnabled: True

MaintenanceEnabled: True

StagingModeEnabled: False

SchedulerSuspended: False

SyncCycleInProgress: False
```

The scheduler was configured to run synchronization
cycles every 30 minutes.

Staging mode was disabled, allowing the server to
perform active synchronization.

### 3.17 Initial Synchronization

An initial synchronization cycle was started using:

```powershell
Start-ADSyncSyncCycle -PolicyType Initial
```

Result:

```text
Success
```

This confirmed that the synchronization cycle was
successfully initiated.

### 3.18 Microsoft Entra ID User Validation

The synchronized identities were checked in:

Microsoft Entra admin center

Entra ID > Users > All users

The following users were verified:

```text
LabUser1
LabUser2
```

Validation results:

- Both users exist in Microsoft Entra ID.
- Their effective cloud UPNs were checked.
- Their identity source indicates on-premises synchronization.



### 3.21 Phase 3 Validation Checklist

- [x] Microsoft Entra tenant identified
- [x] Active Directory forest configured
- [x] LabUsers OU created
- [x] LabGroups OU created
- [x] LabComputers OU created
- [x] FileShare-Users group created
- [x] FileShare-Admins group created
- [x] LabUser1 created
- [x] LabUser2 created
- [x] Group membership configured
- [x] Windows Server prerequisites checked
- [x] Microsoft Entra connectivity validated
- [x] Microsoft Entra Connect installed
- [x] Express Settings configured
- [x] Password Hash Synchronization configured
- [x] ADSync service running
- [x] ADSync PowerShell module loaded
- [x] Synchronization scheduler validated
- [x] Initial synchronization initiated
- [x] LabUser1 synchronized
- [x] LabUser2 synchronized


### 3.22 Phase 3 Status

Microsoft Entra Connect Sync has been successfully installed
and configured on DC01.

The synchronization service is running.

The synchronization scheduler is enabled with a
30-minute interval.

Initial synchronization was initiated successfully.

The lab users were validated in Microsoft Entra ID.

The environment is ready to proceed with the
Azure Files client infrastructure.

## Phase 4 - Windows Client VM

### 4.1 Objective

Deploy a Windows Server client VM using Bicep and automatically
join it to the `lab.contoso.com` Active Directory domain.

The client VM will be used in later phases to reproduce and test:

- Azure Files SMB connectivity
- Active Directory authentication
- Kerberos authentication
- Share-level Azure RBAC permissions
- NTFS permissions
- Private Endpoint connectivity
- Private DNS resolution

### 4.2 Architecture

```text
Resource Group: rg-fileslab
Region: North Europe

vnet-fileslab
Address space: 10.10.0.0/16
│
├── snet-dc
│   Address prefix: 10.10.1.0/24
│   │
│   └── vm-dc01
│       ├── Computer name: DC01
│       ├── Private IP: 10.10.1.10
│       ├── Active Directory Domain Services
│       ├── DNS Server
│       └── Microsoft Entra Connect Sync
│
├── snet-client
│   Address prefix: 10.10.2.0/24
│   │
│   └── vm-client01
│       ├── Computer name: CLIENT01
│       ├── Private IP: 10.10.2.10
│       ├── Windows Server 2022
│       ├── Domain: lab.contoso.com
│       └── OU: LabComputers
│
└── snet-private-endpoints
    Address prefix: 10.10.3.0/24
    │
    └── Reserved for the Azure Files Private Endpoint
```

### 4.3 Client VM Configuration

| Property | Configuration |
|---|---|
| Azure VM name | `vm-client01` |
| Windows computer name | `CLIENT01` |
| Operating system | Windows Server 2022 Datacenter |
| VM size | `Standard_D2s_v5` |
| Azure region | North Europe |
| Virtual network | `vnet-fileslab` |
| Subnet | `snet-client` |
| Private IP | `10.10.2.10` |
| Private IP allocation | Static |
| Public IP | None |
| DNS server | `10.10.1.10` |
| AD DS domain | `lab.contoso.com` |
| Domain join account | `LAB\labadmin` |
| Computer OU | `OU=LabComputers,DC=lab,DC=contoso,DC=com` |
| Administrative access | Azure Bastion |

### 4.4 Active Directory Prerequisites

Before deploying CLIENT01, Domain Controller discovery was validated
from DC01:

```powershell
nltest /dsgetdc:lab.contoso.com
```

Result:

```text
Domain Controller: DC01.lab.contoso.com
Address: 10.10.1.10
Domain: lab.contoso.com
Forest: lab.contoso.com
Site: Default-First-Site-Name
```

The returned flags confirmed that DC01 provides:

- Primary Domain Controller services
- Global Catalog services
- LDAP
- Kerberos Key Distribution Center services
- Time services
- Writable directory services
- DNS services

The target computer OU was validated using:

```powershell
Get-ADOrganizationalUnit `
  -Filter "Name -eq 'LabComputers'"
```

Result:

```text
OU=LabComputers,DC=lab,DC=contoso,DC=com
```

### 4.5 Network Prerequisites

The client subnet was validated using:

```powershell
az network vnet subnet show `
  --resource-group rg-fileslab `
  --vnet-name vnet-fileslab `
  --name snet-client `
  --query "{Name:name,AddressPrefix:addressPrefix}" `
  --output table
```

Result:

```text
Name: snet-client
Address prefix: 10.10.2.0/24
```

The VNet DNS configuration was validated using:

```powershell
az network vnet show `
  --resource-group rg-fileslab `
  --name vnet-fileslab `
  --query "dhcpOptions.dnsServers" `
  --output json
```

Result:

```json
[
  "10.10.1.10"
]
```

This configuration ensures that CLIENT01 uses DC01 for Active
Directory name resolution.

### 4.6 Infrastructure as Code

The client VM infrastructure is defined in:

```text
modules/clientVM.bicep
```

The module deploys:

- Windows Server virtual machine
- Azure network interface
- Static private IP reservation
- Managed operating system disk
- Active Directory domain join extension

The module is called from:

```text
main.bicep
```

### 4.7 Client Network Interface

The following Bicep resource creates the client network interface:

```bicep
resource clientNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIpAddress
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}
```

The network interface uses:

```text
Private IP: 10.10.2.10
Allocation: Static
Subnet: snet-client
```

No public IP address is created.

### 4.8 Client Virtual Machine

The client VM is deployed with:

```bicep
resource clientVM 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: computerName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: clientNic.id
          properties: {
            primary: true
          }
        }
      ]
    }
  }
}
```

### 4.9 Domain Join Automation

The client VM is automatically joined to Active Directory using
the `JsonADDomainExtension`.

```bicep
resource domainJoinExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: clientVM
  name: 'joindomain'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      Name: domainName
      User: domainJoinUsername
      OUPath: ouPath
      Restart: 'true'
      Options: 3
    }
    protectedSettings: {
      Password: domainJoinPassword
    }
  }
}
```

The extension performs the following actions:

1. Resolves the `lab.contoso.com` domain through DC01.
2. Authenticates using the supplied domain join account.
3. Creates or updates the CLIENT01 computer account.
4. Places the computer account in the `LabComputers` OU.
5. Joins CLIENT01 to `lab.contoso.com`.
6. Restarts Windows to complete the operation.

The domain join password is stored in `protectedSettings`.

No passwords are committed to the repository.

### 4.10 Secure Deployment Parameters

The deployment uses three secure parameters:

```text
FILESLAB_VM_PASSWORD
FILESLAB_CLIENT_PASSWORD
FILESLAB_DOMAINJOIN_PASSWORD
```

These values are read from environment variables in
`main.bicepparam`:

```bicep
param adminPassword = readEnvironmentVariable('FILESLAB_VM_PASSWORD')

param clientAdminPassword =
  readEnvironmentVariable('FILESLAB_CLIENT_PASSWORD')

param domainJoinPassword =
  readEnvironmentVariable('FILESLAB_DOMAINJOIN_PASSWORD')
```

The environment variables were validated without displaying
their contents:

```text
FILESLAB_VM_PASSWORD             True
FILESLAB_CLIENT_PASSWORD         True
FILESLAB_DOMAINJOIN_PASSWORD     True
```

The values existed only in the current PowerShell process.

### 4.11 Main Bicep Orchestration

The client module is called from `main.bicep`:

```bicep
module client './modules/clientVM.bicep' = {
  name: 'clientDeployment'
  params: {
    location: location
    vmName: 'vm-client01'
    computerName: 'CLIENT01'
    vmSize: clientVmSize
    adminUsername: clientAdminUsername
    adminPassword: clientAdminPassword
    subnetId: networking.outputs.clientSubnetId
    privateIpAddress: '10.10.2.10'
    domainName: 'lab.contoso.com'
    domainJoinUsername: 'LAB\\labadmin'
    domainJoinPassword: domainJoinPassword
    ouPath: 'OU=LabComputers,DC=lab,DC=contoso,DC=com'
  }
}
```

The main deployment returns:

```bicep
output clientVmId string = client.outputs.vmId
output clientVmName string = client.outputs.vmName
output clientPrivateIp string = client.outputs.privateIp
```

### 4.12 Deployment

The deployment was performed using:

```powershell
az deployment group create `
  --resource-group rg-fileslab `
  --template-file main.bicep `
  --parameters main.bicepparam
```

Deployment result:

```text
Provisioning state: Succeeded
Deployment mode: Incremental
Deployment duration: Approximately 3 minutes and 22 seconds
```

The deployment created:

```text
vm-client01
vm-client01-nic
vm-client01/extensions/joindomain
```

Deployment outputs included:

```text
Client VM name: vm-client01
Client private IP: 10.10.2.10
Client subnet: snet-client
```

### 4.13 Azure Resource Validation

The VM was validated using:

```powershell
az vm show `
  --resource-group rg-fileslab `
  --name vm-client01 `
  --show-details `
  --output table
```

Result:

```text
Name: vm-client01
Resource group: rg-fileslab
Power state: VM running
Location: northeurope
Public IP: None
```

The NIC was validated using:

```powershell
az network nic show `
  --resource-group rg-fileslab `
  --name vm-client01-nic `
  --query "ipConfigurations[].{Name:name,PrivateIP:privateIPAddress,Allocation:privateIPAllocationMethod}" `
  --output table
```

Result:

```text
Name: ipconfig1
Private IP: 10.10.2.10
Allocation: Static
```

### 4.14 Domain Join Extension Validation

The extension was validated using:

```powershell
az vm extension show `
  --resource-group rg-fileslab `
  --vm-name vm-client01 `
  --name joindomain `
  --output json
```

Result:

```text
Extension: joindomain
Publisher: Microsoft.Compute
Type: JsonADDomainExtension
Version: 1.3
Domain: lab.contoso.com
OU: OU=LabComputers,DC=lab,DC=contoso,DC=com
Restart: Enabled
Provisioning state: Succeeded
```

Protected settings and credentials were not displayed.

### 4.15 Windows and Domain Membership Validation

After connecting to CLIENT01 through Azure Bastion, the computer
name was validated:

```powershell
hostname
```

Result:

```text
CLIENT01
```

Domain membership was validated using:

```powershell
Get-CimInstance Win32_ComputerSystem |
  Select-Object Name,Domain,PartOfDomain
```

Result:

```text
Name: CLIENT01
Domain: lab.contoso.com
PartOfDomain: True
```

### 4.16 DNS Validation

The client DNS configuration was checked using:

```powershell
Get-DnsClientServerAddress -AddressFamily IPv4
```

Result:

```text
Interface: Ethernet 2
DNS server: 10.10.1.10
```

CLIENT01 correctly uses DC01 as its DNS server.

### 4.17 Domain Controller Discovery

Domain Controller discovery was tested using:

```powershell
nltest /dsgetdc:lab.contoso.com
```

Result:

```text
Domain Controller: DC01.lab.contoso.com
Address: 10.10.1.10
Domain: lab.contoso.com
Forest: lab.contoso.com
Site: Default-First-Site-Name
```

The returned flags confirmed:

- Primary Domain Controller
- Global Catalog
- LDAP
- Kerberos Key Distribution Center
- Time service
- Writable directory
- DNS services

### 4.18 Domain Secure Channel

The domain secure channel was tested using:

```powershell
Test-ComputerSecureChannel
```

Result:

```text
True
```

This confirmed that CLIENT01 has a valid machine-account
relationship with `lab.contoso.com`.

### 4.19 Active Directory Computer Object

The computer account was queried using:

```powershell
Get-ADComputer `
  -Identity CLIENT01 `
  -Properties DistinguishedName,DNSHostName |
  Select-Object Name,DNSHostName,DistinguishedName
```

Result:

```text
Name: CLIENT01
DNSHostName: CLIENT01.lab.contoso.com
DistinguishedName:
CN=CLIENT01,OU=LabComputers,DC=lab,DC=contoso,DC=com
```

This confirmed that the domain join extension created the
computer object in the intended organizational unit.


### 4.20 Troubleshooting

#### Issue 1: Invalid Environment Variable Method

The first password helper attempted to call:

```powershell
:SetEnvironmentVariable(...)
```

PowerShell interpreted this as a command name and returned:

```text
The term ':SetEnvironmentVariable' is not recognized.
```

The correct .NET method was:

```powershell
[System.Environment]::SetEnvironmentVariable(...)
```

The environment variables were then created at process scope
and validated without displaying their contents.

#### Issue 2: Invalid Environment Variable Validation Method

An initial validation block used:

```powershell
:IsNullOrWhiteSpace(...)
```

This caused a PowerShell parser error.

The variables were instead safely validated using:

```powershell
Test-Path "Env:<variable-name>"
```

All three required variables returned `True`.

#### Issue 3: Client Module Added to the Wrong Bicep File

The client module was initially declared inside:

```text
modules/domainController.bicep
```

This caused the path to resolve as:

```text
modules/modules/clientVM.bicep
```

Bicep returned:

```text
BCP091:
Could not find a part of the path
modules\modules\clientVM.bicep.
```

The client module declaration was removed from
`domainController.bicep` and added to `main.bicep`.

#### Issue 4: Undefined Client Module Outputs

The initial `main.bicep` contained:

```bicep
output clientVmId string = client.outputs.vmId
```

but no valid `client` module declaration existed in that file.

Bicep returned:

```text
BCP057:
The name "client" does not exist in the current context.
```

The corrected `module client` declaration was added to
`main.bicep`.

#### Issue 5: Unused Client Parameters

Bicep initially reported the following parameters as unused:

```text
clientAdminUsername
clientAdminPassword
domainJoinPassword
clientVmSize
```

These warnings occurred because the client module declaration
was missing from `main.bicep`.

Passing the parameters into the corrected client module resolved
the issue.

#### Issue 6: Referenced Module Error

Bicep returned:

```text
BCP104:
The referenced module has errors.
```

This was a secondary error caused by the invalid client module
declaration inside `domainController.bicep`.

Correcting the module placement resolved the referenced-module
error.

#### Issue 7: Active Directory Cmdlet Unavailable on CLIENT01

The following command initially failed:

```powershell
Get-ADComputer CLIENT01
```

Error:

```text
Get-ADComputer is not recognized.
```

The Active Directory PowerShell module was not installed on
CLIENT01.

The required management component was installed using:

```powershell
Install-WindowsFeature RSAT-AD-PowerShell
```

Result:

```text
Success: True
Restart required: No
```

After installing the feature, `Get-ADComputer` completed
successfully.

Installing RSAT was useful for validation but is not required
for normal Azure Files SMB access.

#### Issue 8: Empty Kerberos Cache

The initial `klist` command returned zero cached tickets.

The domain join itself remained healthy, as demonstrated by:

- Successful domain membership
- Correct DNS configuration
- Successful Domain Controller discovery
- Healthy secure channel
- Correct Active Directory computer object

A new interactive sign-in using a domain account is required
to complete user-session Kerberos validation.

### 4.22 Validation Checklist

- [x] Active Directory Domain Controller reachable
- [x] LabComputers OU exists
- [x] Client subnet validated
- [x] VNet DNS configured as 10.10.1.10
- [x] Client Bicep module created
- [x] Client network interface defined
- [x] Client VM defined
- [x] Domain join extension defined
- [x] Secure parameters configured
- [x] Client module added to main.bicep
- [x] Bicep module errors resolved
- [x] Environment variables created
- [x] Environment variables validated
- [x] Deployment completed successfully
- [x] Client VM deployed
- [x] Client NIC deployed
- [x] Client private IP configured as 10.10.2.10
- [x] Client VM running
- [x] Public IP not assigned
- [x] Domain join extension succeeded
- [x] CLIENT01 joined to lab.contoso.com
- [x] Client DNS configured as 10.10.1.10
- [x] Domain Controller discovery succeeded
- [x] Domain secure channel validated
- [x] RSAT Active Directory PowerShell module installed
- [x] CLIENT01 computer account validated
- [x] CLIENT01 computer account placed in LabComputers OU


### 4.23 Phase 4 Status

Phase 4 infrastructure deployment is complete.

CLIENT01 is:

- Running successfully
- Configured with private IP `10.10.2.10`
- Using DC01 for DNS
- Joined to `lab.contoso.com`
- Connected through a valid domain secure channel
- Registered in the `LabComputers` OU
- Ready for Azure Files testing

The remaining validation is to sign in interactively using a
domain account and confirm that the user session receives
Kerberos tickets.

## Phase 5 - Azure Files

### 5.1 Objective

Deploy the Azure Files infrastructure required for private SMB
access from the domain-joined Windows client.

This phase deploys:

- StorageV2 storage account
- Standard SMB file share
- File private endpoint
- Private endpoint network interface
- Azure Private DNS zone
- Private DNS VNet link
- Private DNS zone group

Azure Files AD DS authentication, share-level Azure RBAC, Windows
ACLs, and Kerberos validation are configured in Phase 6.

### 5.2 Architecture

```text
Resource Group: rg-fileslab
Region: North Europe

vnet-fileslab
│
├── snet-dc
│   └── DC01
│       ├── AD DS
│       ├── DNS
│       └── Microsoft Entra Connect Sync
│
├── snet-client
│   └── CLIENT01
│       ├── Domain: lab.contoso.com
│       ├── DNS server: 10.10.1.10
│       └── Azure Files SMB client
│
└── snet-private-endpoints
    └── Azure Files private endpoint
        └── Private address from 10.10.3.0/24

Storage account
└── File service
    └── SMB share: fileshare

Private DNS zone
└── privatelink.file.core.windows.net
    ├── VNet link: vnet-fileslab-link
    └── Storage account A record
```

### 5.3 Planned Configuration

| Component | Configuration |
|---|---|
| Storage account kind | StorageV2 |
| Redundancy | Standard_LRS |
| Access tier | Hot |
| File share | fileshare |
| File share quota | 100 GiB |
| File share protocol | SMB |
| Public network access | Disabled |
| Minimum TLS version | TLS 1.2 |
| Secure transfer | Required |
| Private endpoint | pe-fileslab-file |
| Private endpoint subresource | file |
| Private endpoint subnet | snet-private-endpoints |
| Private DNS zone | privatelink.file.core.windows.net |
| Private DNS VNet link | vnet-fileslab-link |
| Soft delete retention | 7 days |

### 5.4 Infrastructure as Code

The Azure Files resources are defined in:

```text
modules/storage.bicep
```

The module is orchestrated by:

```text
main.bicep
```

The storage module creates:

- Storage account
- File service
- SMB file share
- Private endpoint
- Private endpoint DNS zone group
- Private DNS zone
- Private DNS VNet link

### 5.5 Storage Account Security

The storage account is configured with:

```text
Kind: StorageV2
SKU: Standard_LRS
Public network access: Disabled
Network default action: Deny
Secure transfer: Required
Minimum TLS version: TLS 1.2
Anonymous blob access: Disabled
```

Shared-key access remains temporarily enabled for lab
administration and initial ACL configuration.

Identity-based access will be configured in Phase 6.

### 5.6 SMB Configuration

The file service is configured with:

```text
SMB versions:
- SMB 3.0
- SMB 3.1.1

Authentication methods:
- NTLMv2
- Kerberos

Kerberos ticket encryption:
- AES-256

SMB channel encryption:
- AES-128-GCM
- AES-256-GCM
```

The Azure file share is configured as:

```text
Name: fileshare
Protocol: SMB
Access tier: TransactionOptimized
Quota: 100 GiB
```

### 5.7 Private Endpoint

The private endpoint is configured for the storage account's
`file` subresource.

```text
Private endpoint: pe-fileslab-file
Subnet: snet-private-endpoints
Connection status: Automatically approved
```

The private endpoint provides a private address from:

```text
10.10.3.0/24
```

No public SMB path is required for CLIENT01.

### 5.8 Private DNS

The storage module creates the following private DNS zone:

```text
privatelink.file.core.windows.net
```

The zone is linked to:

```text
vnet-fileslab
```

Automatic registration is disabled because the zone contains
Private Endpoint records rather than VM hostname records.

A private DNS zone group associates the Azure Files private
endpoint with the private DNS zone.

### 5.9 Azure Environment Portability

The first version of the storage module hardcoded:

```text
core.windows.net
```

The Bicep linter returned:

```text
no-hardcoded-env-urls
```

The module was updated to derive the storage DNS suffix from the
current Azure environment:

```bicep
var storageDnsSuffix = environment().suffixes.storage
var fileServiceDnsSuffix = 'file.${storageDnsSuffix}'
var privateDnsZoneName = 'privatelink.${fileServiceDnsSuffix}'
```

The file endpoint is returned using:

```bicep
output fileEndpointFqdn string =
  '${storageAccount.name}.${fileServiceDnsSuffix}'
```

This allows the template to derive the correct suffix for the
target Azure cloud instead of hardcoding a public-cloud hostname.

### 5.10 Bicep Module Boundaries

The first Phase 5 compilation reported:

```text
BCP057:
The name "privateDnsZoneName" does not exist in the current context.

BCP057:
The name "vnetId" does not exist in the current context.

BCP104:
The referenced module has errors.
```

The errors occurred because Private DNS resources were present in
the wrong Bicep module.

The final module responsibilities are:

```text
network.bicep
├── Network security group
├── Virtual network
├── Domain Controller subnet
├── Client subnet
└── Private Endpoint subnet

storage.bicep
├── Storage account
├── File service
├── File share
├── Private DNS zone
├── Private DNS VNet link
├── Private endpoint
└── Private DNS zone group
```

The network module exposes:

```bicep
output vnetId string = vnet.id
output dcSubnetId string = dcSubnet.id
output clientSubnetId string = clientSubnet.id
output peSubnetId string = peSubnet.id
```

The storage module consumes the VNet and Private Endpoint subnet
resource IDs through parameters.

### 5.11 Secure Parameter Troubleshooting

The parameter compilation initially returned:

```text
BCP427:
Environment variable FILESLAB_VM_PASSWORD does not exist.

BCP427:
Environment variable FILESLAB_CLIENT_PASSWORD does not exist.

BCP427:
Environment variable FILESLAB_DOMAINJOIN_PASSWORD does not exist.
```

The error occurred because process-level environment variables
exist only in the PowerShell process in which they were created.

The three variables were recreated in the terminal used for the
Bicep deployment:

```text
FILESLAB_VM_PASSWORD
FILESLAB_CLIENT_PASSWORD
FILESLAB_DOMAINJOIN_PASSWORD
```

The variables were validated without displaying their values.

No passwords were stored in:

```text
main.bicepparam
```

or committed to the repository.

### 5.12 Deployment

The Azure Files infrastructure was deployed using:

```powershell
az deployment group create `
  --resource-group rg-fileslab `
  --template-file main.bicep `
  --parameters main.bicepparam
```

The deployment completed successfully.


### 5.15 Phase 5 Status

The Azure Files infrastructure has been deployed successfully.

The storage account, SMB file share, Private Endpoint, and private
DNS integration are present in the Bicep deployment.

Private DNS and SMB connectivity validation must be completed
before enabling Azure Files AD DS authentication.

## Phase 6 - Azure Files AD DS Authentication and Permissions

### 6.1 Objective

Enable Active Directory Domain Services identity-based authentication for the Azure file share and validate Kerberos-based SMB access from CLIENT01.

This phase configures:

- Azure Files AD DS authentication
- Storage account registration in Active Directory
- AES-256 Kerberos encryption
- Share-level Azure RBAC permissions
- Directory-level and file-level Windows ACLs
- Private Endpoint SMB connectivity
- Kerberos authentication from CLIENT01
- Identity-based file-share mounting

### 6.2 Configuration

| Component | Configuration |
|---|---|
| Resource group | `rg-fileslab` |
| Storage account | `stfileslabzyrjbom25doq2` |
| File share | `fileshare` |
| File endpoint | `stfileslabzyrjbom25doq2.file.core.windows.net` |
| Private Endpoint address | `10.10.3.4` |
| Identity source | Active Directory Domain Services |
| AD DS domain | `lab.contoso.com` |
| NetBIOS domain | `LAB` |
| Storage AD object type | Computer account |
| Storage AD object OU | `LabComputers` |
| Kerberos encryption | AES-256 |
| Standard access group | `FileShare-Users` |
| Administrative access group | `FileShare-Admins` |
| Standard access role | Storage File Data SMB Share Contributor |
| Administrative access role | Storage File Data SMB Share Elevated Contributor |
| Windows ACL tool | `icacls` |
| SMB client | CLIENT01 |

### 6.3 Authentication and Authorization Model

Azure Files access is controlled through two authorization layers:

1. **Share-level permissions**

   Azure RBAC determines whether an identity can access the Azure file share.

2. **Directory-level and file-level permissions**

   Windows ACLs determine which directories and files the identity can access and which operations it can perform.

Both authorization layers must allow access.

The effective access is determined by the most restrictive combination of:

```text
Azure RBAC share-level permission
+
Windows directory and file ACLs
```

The following access model was configured:

| Active Directory group | Azure RBAC role | Windows ACL |
|---|---|---|
| `LAB\FileShare-Users` | Storage File Data SMB Share Contributor | Modify |
| `LAB\FileShare-Admins` | Storage File Data SMB Share Elevated Contributor | Full Control |

### 6.4 Active Directory Prerequisites

The following Active Directory organizational unit was already available:

```text
OU=LabComputers,DC=lab,DC=contoso,DC=com
```

The following security groups were also available:

```text
LAB\FileShare-Users
LAB\FileShare-Admins
```

The test administrator was confirmed as a member of the administrative group:

```powershell
Get-ADGroupMember "FileShare-Admins" -Recursive |
  Where-Object SamAccountName -eq "labadmin" |
  Select-Object Name,SamAccountName,SID
```

Result:

```text
Name: labadmin
SamAccountName: labadmin
SID: S-1-5-21-3694672068-562638810-543667067-500
```

### 6.5 Microsoft Entra Group Validation

The synchronized security groups were identified in Microsoft Entra ID:

```powershell
az ad group list `
  --query "[].{DisplayName:displayName,ObjectId:id}" `
  --output table
```

The following group object IDs were confirmed:

| Group | Microsoft Entra object ID |
|---|---|
| FileShare-Users | `1ec6724a-2fbd-45e2-adfd-9e31f30af16b` |
| FileShare-Admins | `af2fce25-4042-4361-97ee-9beec89a8244` |

These object IDs were used for the Azure RBAC role assignments.

The Microsoft Entra object IDs are different from the Active Directory object GUIDs and SIDs. Azure RBAC assignments must use the Microsoft Entra object IDs.

### 6.6 AzFilesHybrid Module

The AzFilesHybrid PowerShell module was used to register the storage account in Active Directory and enable Azure Files AD DS authentication.

The module was located at:

```text
C:\AzFilesHybrid\AzFilesHybrid.psd1
```

The module was imported using its full manifest path:

```powershell
Import-Module `
  "C:\AzFilesHybrid\AzFilesHybrid.psd1" `
  -Force `
  -Verbose
```

The required command was validated using:

```powershell
Get-Command Join-AzStorageAccountForAuth
```

This confirmed that the command was exported by the AzFilesHybrid module.

### 6.7 Storage Account Registration in Active Directory

The storage account was registered in Active Directory as a computer account.

The storage account name was defined as:

```powershell
$storageAccountName = "stfileslabzyrjbom25doq2"
```

The AD DS registration was performed using:

```powershell
Join-AzStorageAccountForAuth `
  -ResourceGroupName "rg-fileslab" `
  -StorageAccountName $storageAccountName `
  -DomainAccountType "ComputerAccount" `
  -OrganizationalUnitDistinguishedName `
    "OU=LabComputers,DC=lab,DC=contoso,DC=com"
```

This operation:

1. Created a computer account representing the storage account.
2. Placed the computer account in the `LabComputers` OU.
3. Configured the required service principal names.
4. Enabled AD DS authentication on the storage account.
5. Configured the storage account domain properties.

The configuration uses AES-256 Kerberos encryption.

### 6.8 Share Resource Scope

The Azure file-share resource ID was obtained using:

```powershell
$storageAccountName = "stfileslabzyrjbom25doq2"
$fileShareName = "fileshare"

$shareScope = az storage share-rm show `
  --resource-group "rg-fileslab" `
  --storage-account $storageAccountName `
  --name $fileShareName `
  --query id `
  --output tsv
```

The resulting scope was:

```text
/subscriptions/5574adb9-34c7-49b2-b8dc-5581a810c68b/resourceGroups/rg-fileslab/providers/Microsoft.Storage/storageAccounts/stfileslabzyrjbom25doq2/fileServices/default/shares/fileshare
```

### 6.9 Share-Level Azure RBAC

Share-level Azure RBAC permissions were assigned to the synchronized Microsoft Entra groups.

The variables were configured as:

```powershell
$usersGroupObjectId = `
  "1ec6724a-2fbd-45e2-adfd-9e31f30af16b"

$adminsGroupObjectId = `
  "af2fce25-4042-4361-97ee-9beec89a8244"
```

The standard users group received the following role:

```text
Storage File Data SMB Share Contributor
```

The role was assigned using:

```powershell
az role assignment create `
  --assignee-object-id $usersGroupObjectId `
  --assignee-principal-type Group `
  --role "Storage File Data SMB Share Contributor" `
  --scope $shareScope
```

The administrators group received the following role:

```text
Storage File Data SMB Share Elevated Contributor
```

The role was assigned using:

```powershell
az role assignment create `
  --assignee-object-id $adminsGroupObjectId `
  --assignee-principal-type Group `
  --role "Storage File Data SMB Share Elevated Contributor" `
  --scope $shareScope
```

The role assignments were validated using:

```powershell
az role assignment list `
  --scope $shareScope `
  --include-inherited `
  --query "[].{Principal:principalName,ObjectId:principalId,Role:roleDefinitionName,Scope:scope}" `
  --output table
```

The final assignments were:

```text
FileShare-Users
Storage File Data SMB Share Contributor
```

```text
FileShare-Admins
Storage File Data SMB Share Elevated Contributor
```

### 6.10 Initial Administrative Mount

The Azure RBAC assignments granted share-level access, but the Windows ACLs still had to be initialized.

The file share was temporarily mounted using the storage account key to establish the initial directory-level and file-level permissions.

The storage account key was retrieved for the administrative operation:

```powershell
$storageKey = az storage account keys list `
  --resource-group "rg-fileslab" `
  --account-name $storageAccountName `
  --query "[0].value" `
  --output tsv
```

The share path was defined as:

```powershell
$fileEndpointFqdn = `
  "$storageAccountName.file.core.windows.net"

$sharePath = `
  "\\$fileEndpointFqdn\$fileShareName"
```

The temporary administrative mount was created using:

```powershell
net use T: $sharePath `
  /user:"Azure\$storageAccountName" `
  $storageKey `
  /persistent:no
```

The storage account key was used only to initialize the Windows ACLs.

Normal user access uses AD DS authentication and Kerberos instead of the storage account key.

### 6.11 Windows ACL Configuration

Windows ACLs were configured using `icacls`.

The administrators group received Full Control:

```powershell
icacls T:\ `
  /grant:r "LAB\FileShare-Admins:(OI)(CI)(F)"
```

The standard users group received Modify permission:

```powershell
icacls T:\ `
  /grant:r "LAB\FileShare-Users:(OI)(CI)(M)"
```

The inheritance flags have the following meanings:

| Flag | Meaning |
|---|---|
| `(OI)` | Files inherit the access control entry |
| `(CI)` | Directories inherit the access control entry |
| `(F)` | Full Control |
| `(M)` | Modify |

The resulting ACL was validated using:

```powershell
icacls T:\
```

After configuring the ACLs, the temporary key-based connection was removed:

```powershell
net use T: /delete /y
```

The key variable was then cleared:

```powershell
$storageKey = $null
```

### 6.12 CLIENT01 Domain Validation

The test was performed from CLIENT01 using:

```text
LAB\labadmin
```

The logged-in identity was confirmed using:

```powershell
whoami
```

Result:

```text
lab\labadmin
```

The domain secure channel was validated using:

```powershell
nltest /sc_verify:lab.contoso.com
```

Result:

```text
Trusted DC: DC01.lab.contoso.com
Trusted DC Connection Status: NERR_Success
Trust Verification Status: NERR_Success
```

This confirmed that CLIENT01 maintained a healthy trust relationship with the domain.

### 6.13 DNS Validation

The Azure Files endpoint was defined using:

```powershell
$storageAccountName = "stfileslabzyrjbom25doq2"
$fileShareName = "fileshare"

$fileEndpointFqdn = `
  "$storageAccountName.file.core.windows.net"
```

DNS resolution was tested using:

```powershell
Resolve-DnsName $fileEndpointFqdn
```

Result:

```text
Canonical name:
stfileslabzyrjbom25doq2.privatelink.file.core.windows.net

IPv4 address:
10.10.3.4
```

The public Azure Files hostname correctly resolved through the Private Endpoint DNS path:

```text
stfileslabzyrjbom25doq2.file.core.windows.net
                 |
                 v
stfileslabzyrjbom25doq2.privatelink.file.core.windows.net
                 |
                 v
10.10.3.4
```

This confirmed that CLIENT01 used the private Azure Files endpoint.

### 6.14 SMB Connectivity Validation

TCP connectivity to the Azure Files SMB endpoint was validated using:

```powershell
Test-NetConnection `
  -ComputerName $fileEndpointFqdn `
  -Port 445
```

Result:

```text
ComputerName:
stfileslabzyrjbom25doq2.file.core.windows.net

RemoteAddress:
10.10.3.4

RemotePort:
445

SourceAddress:
10.10.2.10

TcpTestSucceeded:
True
```

This confirmed:

- Private Endpoint routing was operational.
- DNS returned the expected private IP address.
- TCP port 445 was reachable.
- No NSG, route, or firewall rule blocked SMB connectivity.

### 6.15 Kerberos Ticket Validation

Existing Kerberos tickets were cleared using:

```powershell
klist purge
```

A CIFS service ticket was explicitly requested using:

```powershell
klist get "cifs/$fileEndpointFqdn"
```

The ticket was retrieved successfully.

Confirmed ticket properties:

```text
Client:
labadmin@LAB.CONTOSO.COM

Service:
cifs/stfileslabzyrjbom25doq2.file.core.windows.net

Kerberos realm:
LAB.CONTOSO.COM

Encryption:
AES-256-CTS-HMAC-SHA1-96

KDC:
DC01.lab.contoso.com
```

This confirmed that:

- The domain user obtained a Kerberos ticket.
- The CIFS service principal name was available.
- DC01 successfully issued the service ticket.
- The storage account AD object was configured correctly.
- AES-256 Kerberos encryption was used.
- The ticket targeted the exact Azure Files hostname used by the SMB client.

### 6.16 Identity-Based SMB Mount

Existing SMB connections were removed before the final test:

```powershell
net use * /delete /y
```

The final share path was defined as:

```powershell
$sharePath = `
  "\\stfileslabzyrjbom25doq2.file.core.windows.net\fileshare"
```

The file share was mounted using the signed-in domain identity:

```powershell
net use Z: $sharePath /persistent:no
```

No storage account key or alternate username was provided for the final mount.

The connection used:

```text
LAB\labadmin
```

The drive was mounted successfully after:

1. AD DS authentication was enabled.
2. Share-level Azure RBAC roles were assigned.
3. Windows ACLs were configured.
4. The administrative key-based SMB session was removed.
5. The client obtained a new Kerberos ticket.

### 6.17 SMB Session Validation

The SMB connection was validated using:

```powershell
Get-SmbConnection |
  Select-Object `
    ServerName,
    ShareName,
    UserName,
    Dialect,
    NumOpens
```

The mapped drive was also validated using:

```powershell
Get-ChildItem Z:\
```

The domain identity could access the Azure file share according to its Azure RBAC and Windows ACL permissions.

### 6.18 Troubleshooting

#### Issue 1: `Join-AzStorageAccountForAuth` Not Recognized

The following command initially failed:

```powershell
Join-AzStorageAccountForAuth
```

Error:

```text
The term 'Join-AzStorageAccountForAuth'
is not recognized as the name of a cmdlet,
function, script file, or operable program.
```

Investigation showed that:

```powershell
Get-Module AzFilesHybrid -ListAvailable
```

returned no result.

The AzFilesHybrid manifest was located at:

```text
C:\AzFilesHybrid\AzFilesHybrid.psd1
```

**Cause:**

The module had been downloaded but was not installed in a recognized PowerShell module path and was not loaded in the current session.

**Resolution:**

The module was imported directly using its manifest:

```powershell
Import-Module `
  "C:\AzFilesHybrid\AzFilesHybrid.psd1" `
  -Force
```

The command was then validated:

```powershell
Get-Command Join-AzStorageAccountForAuth
```

**Status:** Resolved.

#### Issue 2: Empty PowerShell Variables

Several Azure CLI commands returned:

```text
expected one argument
```

The affected parameters included:

```text
--storage-account
--assignee-object-id
--scope
```

**Cause:**

The following PowerShell variables were empty in the current session:

```text
$storageAccountName
$fileShareName
$usersGroupObjectId
$adminsGroupObjectId
$shareScope
```

PowerShell variables are scoped to the current process and were not retained between sessions.

**Resolution:**

The variables were explicitly defined before executing the Azure CLI commands:

```powershell
$storageAccountName = `
  "stfileslabzyrjbom25doq2"

$fileShareName = `
  "fileshare"

$usersGroupObjectId = `
  "1ec6724a-2fbd-45e2-adfd-9e31f30af16b"

$adminsGroupObjectId = `
  "af2fce25-4042-4361-97ee-9beec89a8244"
```

**Status:** Resolved.

#### Issue 3: Placeholder Group Names Used as Commands

The following placeholder was initially passed to Azure CLI:

```text
<users-group-display-name>
```

PowerShell returned:

```text
The system cannot find the file specified.
```

**Cause:**

The placeholder text was not replaced with the actual group name. The angle brackets were also interpreted by the command shell rather than treated as part of a valid group name.

**Resolution:**

The actual group names and confirmed Microsoft Entra object IDs were used:

```text
FileShare-Users
FileShare-Admins
```

**Status:** Resolved.

#### Issue 4: Share-Level RBAC Roles Not Assigned

The client successfully completed:

- Domain trust validation
- Private DNS resolution
- TCP 445 connectivity
- Kerberos CIFS ticket acquisition

However, the SMB mount still failed.

**Cause:**

The required Azure Files share-level RBAC roles had not been assigned to the synchronized Microsoft Entra security groups.

A valid Kerberos ticket confirmed authentication, but authentication alone did not grant authorization to the share.

**Resolution:**

The following assignments were created:

```text
FileShare-Users
Storage File Data SMB Share Contributor
```

```text
FileShare-Admins
Storage File Data SMB Share Elevated Contributor
```

**Status:** Resolved.

#### Issue 5: Windows ACLs Not Configured

After assigning Azure RBAC, the groups had share-level authorization, but the root directory ACL did not yet grant the required file-system permissions.

**Cause:**

Azure RBAC and Windows ACLs are independent authorization layers.

The Azure role assignment allowed the identity to pass the share-level access check, but the directory-level and file-level permissions still had to be configured.

**Resolution:**

The share was temporarily mounted using the storage account key. The required Windows ACLs were then assigned using `icacls`:

```powershell
icacls T:\ `
  /grant:r "LAB\FileShare-Admins:(OI)(CI)(F)"
```

```powershell
icacls T:\ `
  /grant:r "LAB\FileShare-Users:(OI)(CI)(M)"
```

The temporary key-based connection was removed after the ACL configuration.

**Status:** Resolved.

#### Issue 6: Access Denied During Initial Kerberos Mount

The first identity-based mount returned:

```text
Access is denied.
```

A subsequent attempt prompted for a username and password and returned:

```text
System error 1326 has occurred.

The user name or password is incorrect.
```

The investigation confirmed:

```text
DNS resolution: Successful
Private Endpoint address: 10.10.3.4
TCP 445: Successful
Domain trust: Successful
Kerberos CIFS ticket: Successfully issued
Encryption: AES-256
```

**Cause:**

The issue was not related to DNS, networking, domain trust, or Kerberos authentication.

The failure occurred because:

1. The Azure RBAC roles were not initially assigned.
2. The Windows ACLs had not yet been initialized.

The credential prompt represented an authentication fallback after the Kerberos-authenticated session could not obtain the required authorization.

**Resolution:**

The Azure RBAC roles were assigned, and the Windows ACLs were configured through the temporary administrative mount.

The file share was then mounted successfully using the domain identity.

**Status:** Resolved.

#### Issue 7: Microsoft Entra Join Diagnostics

The following values were observed in `dsregcmd /status`:

```text
AzureAdJoined: NO
AzureAdPrt: NO
AD Configuration Test: FAIL
```

These values did not prevent access.

**Explanation:**

CLIENT01 uses on-premises AD DS authentication for Azure Files.

The client requirements for this scenario were:

- AD DS domain membership
- Connectivity to DC01
- Healthy domain secure channel
- Correct DNS configuration
- Kerberos ticket acquisition
- Azure RBAC authorization
- Windows ACL authorization

Microsoft Entra join and a Microsoft Entra Primary Refresh Token were not required for the configured AD DS authentication model.

No corrective action was required.

### 6.19 Security Considerations

The storage account key was used only for the initial administrative ACL configuration.

The key must not be:

- Stored in the repository
- Written to transcript files
- Printed to the console
- Embedded directly in scripts
- Used for normal end-user file access

Normal file-share access uses:

```text
Active Directory identity
+
Kerberos authentication
+
Azure RBAC
+
Windows ACLs
```

After initialization, users and administrators access the share using their domain identities.

In a production environment:

- Storage account key access should be minimized.
- Secrets should be retrieved from a protected secret store.
- Administrative ACL changes should use a dedicated identity.
- RBAC assignments should follow least privilege.
- Storage account keys should be rotated if exposure is suspected.
- Administrative and user permissions should be managed through separate groups.

### 6.20 Phase 6 Validation Checklist

- [x] AzFilesHybrid module located
- [x] AzFilesHybrid module imported
- [x] `Join-AzStorageAccountForAuth` command validated
- [x] Storage account registered in Active Directory
- [x] Storage computer account placed in `LabComputers`
- [x] AD DS authentication enabled for Azure Files
- [x] AES-256 Kerberos encryption configured
- [x] FileShare-Users synchronized to Microsoft Entra ID
- [x] FileShare-Admins synchronized to Microsoft Entra ID
- [x] Microsoft Entra group object IDs identified
- [x] File-share Azure resource scope identified
- [x] Storage File Data SMB Share Contributor assigned
- [x] Storage File Data SMB Share Elevated Contributor assigned
- [x] File share temporarily mounted for ACL initialization
- [x] FileShare-Users Windows ACL configured
- [x] FileShare-Admins Windows ACL configured
- [x] Temporary key-based connection removed
- [x] CLIENT01 domain membership validated
- [x] Domain secure channel validated
- [x] Azure Files hostname resolved through Private DNS
- [x] Private Endpoint address validated as `10.10.3.4`
- [x] TCP port 445 connectivity validated
- [x] CIFS Kerberos ticket retrieved
- [x] AES-256 ticket encryption validated
- [x] DC01 confirmed as the Kerberos KDC
- [x] Identity-based SMB mount completed
- [x] Azure Files access validated through the mapped drive

### 6.21 Phase 6 Status

Azure Files AD DS authentication and authorization have been successfully configured.

The storage account is registered in the `lab.contoso.com` Active Directory domain as a computer account.

The synchronized Active Directory groups have the required Azure Files share-level RBAC roles.

The Windows ACLs grant:

```text
LAB\FileShare-Users
Modify
```

```text
LAB\FileShare-Admins
Full Control
```

CLIENT01 successfully:

- Resolves the Azure Files endpoint through Private DNS
- Connects to the Private Endpoint over TCP port 445
- Obtains an AES-256 Kerberos CIFS ticket from DC01
- Authenticates using the signed-in AD DS identity
- Mounts the Azure file share through SMB
- Accesses the share according to Azure RBAC and Windows ACL permissions

Phase 6 is complete.

The Azure Files AD DS lab deployment is fully operational.


