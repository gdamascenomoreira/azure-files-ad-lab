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

### Phase 4 - Client VM
Deploy and domain-join the Windows client.

### Phase 5 - Azure Files
Deploy the storage account, file share,
and private endpoint.

### Phase 6 - Authentication
Configure Azure Files AD DS authentication,
RBAC, and NTFS permissions.

### Phase 7 - Validation
Validate DNS, SMB connectivity, Kerberos,
and file share access.

## 4. Deployment History

### Step 1 - GitHub Repository

Created the public GitHub repository:
gdamascenomoreira/azure-files-ad-lab

### Step 2 - Local Development

Cloned the repository using Visual Studio Code.

Verified the Git remote using:

git remote -v

### Step 3 - Project Structure

Created the initial project folders and files.

## 5. Troubleshooting

Troubleshooting procedures and findings will be
documented as the project progresses.