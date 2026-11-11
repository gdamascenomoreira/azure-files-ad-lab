# Azure Files AD DS Lab: How It Works

This guide explains what the lab deploys, how each part is configured, how to verify it and how to troubleshoot it.

To deploy the lab, follow the [Quick Start](quick-start.md). This guide is the reference behind it: use it to understand a step, to check a component by hand, or to reproduce a customer scenario.

## Contents

1. [Architecture](#1-architecture)
2. [Design decisions](#2-design-decisions)
3. [Deployment flow](#3-deployment-flow)
4. [Network](#4-network)
5. [Domain Controller](#5-domain-controller)
6. [Microsoft Entra Connect Sync](#6-microsoft-entra-connect-sync)
7. [Azure Files](#7-azure-files)
8. [Storage account AD DS join](#8-storage-account-ad-ds-join)
9. [Client](#9-client)
10. [Authorization model](#10-authorization-model)
11. [Validation](#11-validation)
12. [Troubleshooting and lessons learned](#12-troubleshooting-and-lessons-learned)
13. [Security considerations](#13-security-considerations)

## 1. Architecture

```
                         Microsoft Entra ID (test tenant)
                                     ▲
                                     │ Entra Connect Sync (users, groups, SIDs)
                                     │
┌─ vnet-fileslab 10.10.0.0/16 ───────┼────────────────────────────────────────┐
│  DNS servers: 10.10.1.10 (DC01)    │                                        │
│                                    │                                        │
│  snet-dc 10.10.1.0/24        snet-client 10.10.2.0/24                       │
│  ┌──────────────────────┐    ┌──────────────────────┐                       │
│  │ DC01  10.10.1.10     │◄───┤ CLIENT01 10.10.2.10  │                       │
│  │ AD DS + DNS          │ Kerberos  domain-joined   │                       │
│  │ Entra Connect Sync   │    │ AzFilesHybrid        │                       │
│  └──────────┬───────────┘    └──────────┬───────────┘                       │
│             │ forwarder 168.63.129.16   │ SMB 445 (Kerberos)                │
│             ▼                           ▼                                   │
│  snet-private-endpoints 10.10.3.0/24                                        │
│  ┌──────────────────────────────────────────────┐                           │
│  │ pe-fileslab-file  10.10.3.x                  │                           │
│  └──────────────────────┬───────────────────────┘                           │
└─────────────────────────┼───────────────────────────────────────────────────┘
                          ▼
             stfiles<random> (public access disabled)
             └── fileshare (SMB, AD DS authentication)

  privatelink.file.core.windows.net (Private DNS zone, linked to the VNet)
```

| Component | Name | Address | Role |
|---|---|---|---|
| Domain Controller | `vm-dc01` (DC01) | `10.10.1.10` | AD DS forest `lab.contoso.com`, DNS, Entra Connect Sync |
| Client | `vm-client01` (CLIENT01) | `10.10.2.10` | Domain-joined client that mounts the share |
| Storage account | `stfiles<random>` | Private endpoint `10.10.3.x` | Azure file share `fileshare` |
| Private DNS zone | `privatelink.file.core.windows.net` | | Resolves the storage account to the private endpoint |

Lab identities:

| Object | Location | Purpose |
|---|---|---|
| `LAB\labadmin` | Users container | Domain Admin and Enterprise Admin (the DC's local admin before promotion) |
| `LabUser1`, `LabUser2` | `OU=LabUsers` | Test users, members of `FileShare-Users` |
| `FileShare-Users` | `OU=LabGroups` | Share-level Contributor, NTFS Modify |
| `FileShare-Admins` | `OU=LabGroups` | Share-level Elevated Contributor, NTFS Full Control |
| `stfiles<random>` | `OU=LabComputers` | Computer object that represents the storage account |
| `CLIENT01` | `OU=LabComputers` | Client computer object |

## 2. Design decisions

| Decision | Reason |
|---|---|
| **Entra Connect Sync on DC01**, no separate sync server | Keeps the lab small and cheap. A dedicated sync server is preferable in production (see [Security considerations](#13-security-considerations)). |
| **Run Commands** (`Microsoft.Compute/virtualMachines/runCommands`) for in-guest configuration | Declared in Bicep, chained with `dependsOn`, secrets passed as protected parameters, and a script failure fails the deployment (`treatFailureAsDeploymentFailure`). |
| **Scripts are idempotent** | Every script checks the current state first, so a redeploy or a manual rerun is safe. |
| **Storage account AD DS join without AzFilesHybrid** | The join calls the Azure Resource Manager REST API with the DC's managed identity. Nothing is downloaded at deploy time, which removes the most fragile step. The result is the same as `Join-AzStorageAccountForAuth -DomainAccountType ComputerAccount`. |
| **Storage account name limited to 15 characters** | The name becomes an AD computer name (`sAMAccountName` limit). |
| **Subnets declared inline in the VNet** | Separate subnet resources are written in parallel and fail with `AnotherOperationInProgress`. Inline subnets also survive redeploys. |
| **Short wait after the DC promotion** (`deploymentScripts`) | A Run Command that is running when Windows restarts is interrupted. The wait ensures the AD configuration starts after the restart. |
| **Default share-level permission `None`** | Access only through RBAC on the synced groups, as most customers configure it. Can be changed per deployment. |
| **Secrets in environment variables** | `main.bicepparam` reads them with `readEnvironmentVariable`, so they never reach the repository. |
| **Entra Connect installed with the wizard** | Microsoft supports Entra Connect Sync installation only through the wizard, and the installer is only available from the Microsoft Entra admin center. Everything around it is automated. |

## 3. Deployment flow

```
network ──┬── DC VM → install-adds → promote-dc → wait for restart → configure-ad → prepare-entra-connect ──┬── CLIENT01 + domain join → prepare-client ──┬── set-share-acl
          │                                                                                                └── join-storage-ad                         │
          └── storage account + file share + private endpoint + private DNS ──────────────────────────────────────────────────────────────────────────┘
```

| # | Step | Resource | Script | Runs on |
|---|---|---|---|---|
| 1 | Network | `network.bicep` | | |
| 2 | Storage, share, private endpoint, DNS zone | `storage.bicep` | | |
| 3 | Install AD DS role | Run Command `install-adds` | `Install-ADDS.ps1` | DC01 |
| 4 | Create the forest | Run Command `promote-dc` | `Promote-DC.ps1` | DC01 |
| 5 | Wait for the post-promotion restart | `deploymentScripts` `wait-for-vm-dc01-reboot` | `sleep` | Azure Container Instance |
| 6 | DNS forwarder, UPN suffix, OUs, groups, users | Run Command `configure-ad` | `Configure-ADLab.ps1` | DC01 |
| 7 | Entra Connect prerequisites | Run Command `prepare-entra-connect` | `Prepare-EntraConnect.ps1` | DC01 |
| 8 | Storage account AD DS join, default share permission | Run Command `join-storage-ad` | `Join-StorageAccountToAD.ps1` | DC01 |
| 9 | Domain join | Extension `joindomain` | | CLIENT01 |
| 10 | Remote Desktop Users, AD module, AzFilesHybrid | Run Command `prepare-client` | `Prepare-Client.ps1` | CLIENT01 |
| 11 | Windows ACLs on the share root | Run Command `set-share-acl` | `Set-ShareAcl.ps1` | CLIENT01 |
| 12 | Entra Connect Sync | Wizard (manual) | | DC01 |
| 13 | Share-level RBAC for the synced groups | | `Set-ShareRbac.ps1` | Your workstation |
| 14 | Smoke test | Run Command `smoke-test` | `Test-FileShareAccess.ps1` | CLIENT01 |

Steps 1 to 11 are one Bicep deployment. Steps 12 to 14 follow the [Quick Start](quick-start.md).

To read the output of any Run Command:

```powershell
az vm run-command show --name <run-command> --vm-name <vm> -g $rg --expand instanceView --query instanceView.output -o tsv
```

> The output in `instanceView` is limited to the last 4 KB.

## 4. Network

**Module:** `modules/network.bicep`

| Setting | Value | Why |
|---|---|---|
| Address space | `10.10.0.0/16` | |
| `snet-dc` | `10.10.1.0/24` | DC01 |
| `snet-client` | `10.10.2.0/24` | CLIENT01 |
| `snet-private-endpoints` | `10.10.3.0/24` | Private endpoint of the storage account |
| VNet DNS servers | `10.10.1.10` | Every VM resolves through DC01, so the domain and the private endpoint resolve correctly |
| `privateEndpointNetworkPolicies` | `Disabled` | Set explicitly so what-if shows no changes on redeploy |
| NSG | `vnet-fileslab-nsg` on `snet-dc` and `snet-client` | Default rules |

The VMs have no public IP. Access is through Azure Bastion, created from the portal (see the Quick Start).

**Verify:**

```powershell
az network vnet show -g $rg -n vnet-fileslab --query "{dns:dhcpOptions.dnsServers, subnets:subnets[].{name:name, prefix:addressPrefix}}"
```

## 5. Domain Controller

**Module:** `modules/domainController.bicep`. VM `vm-dc01`, Windows Server 2022, `Standard_D2s_v5`, static private IP `10.10.1.10`, system-assigned managed identity.

### 5.1 Install AD DS (`Install-ADDS.ps1`)

Installs the `AD-Domain-Services` role with the management tools. Skips if the role is already installed.

### 5.2 Promote to Domain Controller (`Promote-DC.ps1`)

Creates the forest with `Install-ADDSForest`:

| Setting | Value |
|---|---|
| Domain | `lab.contoso.com` (parameter `domainName`). If you change it, use your value wherever this guide shows `lab.contoso.com` or `LAB` |
| NetBIOS name | `LAB` (parameter `netbiosName`) |
| DNS | Installed on DC01 |
| DSRM password | Protected parameter from `FILESLAB_DSRM_PASSWORD` |

The script uses `-NoRebootOnCompletion` and schedules the restart 60 seconds later, so the Run Command can report success before Windows restarts. It skips if the server is already a DC.

Expected warnings during the promotion, which need no action:

| Warning | Explanation |
|---|---|
| No static IP on the network adapter | Windows uses DHCP; Azure reserves `10.10.1.10` on the NIC. Don't set a static IP inside Windows on an Azure VM. |
| DNS delegation can't be created | `lab.contoso.com` is an isolated forest with no parent zone. |
| Cryptography algorithms compatible with Windows NT 4.0 are blocked | Secure Windows Server 2022 default, kept as is. |

### 5.3 Wait for the restart

A `Microsoft.Resources/deploymentScripts` resource sleeps 180 seconds (parameter `rebootWaitSeconds`). It runs in an Azure Container Instance with no identity, and creates a temporary storage account that is deleted afterwards.

### 5.4 Configure AD (`Configure-ADLab.ps1`)

1. Waits up to 20 minutes for AD DS after the restart.
2. Sets the DNS forwarder to Azure DNS, `168.63.129.16`. Without it, DC01 can't resolve `privatelink.file.core.windows.net`, and the storage account resolves to a public IP that is blocked.
3. Adds the UPN suffix `FILESLAB_UPN_SUFFIX` to the forest, when set.
4. Creates the OUs `LabUsers`, `LabGroups` and `LabComputers`.
5. Creates `FileShare-Users` and `FileShare-Admins` (global security groups).
6. Creates `LabUser1` and `LabUser2` (password never expires), and adds them to `FileShare-Users`.

### 5.5 Verify

On DC01:

```powershell
Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainSID
Get-ADForest | Select-Object Name, UPNSuffixes
Get-DnsServerForwarder
Get-ADOrganizationalUnit -Filter * | Select-Object Name
Get-ADGroupMember FileShare-Users | Select-Object SamAccountName
Resolve-DnsName <storage-account>.file.core.windows.net   # must return 10.10.3.x
nltest /dsgetdc:lab.contoso.com
```

> `dcdiag /q` right after the promotion can report `DFSREvent` warnings from the SYSVOL initialization. If `Get-Service DFSR` is running and later runs are clean, they are historical and need no action.

## 6. Microsoft Entra Connect Sync

### 6.1 Preparation (`Prepare-EntraConnect.ps1`)

Runs at the end of the DC configuration:

- Enables TLS 1.2 for .NET Framework and SCHANNEL.
- Turns off IE Enhanced Security Configuration for administrators, so the sign-in pages load in the wizard.
- Checks the prerequisites and fails the deployment if one is missing: Windows Server, .NET 4.8, 4 GB memory, 70 GB free disk, DC discovery, and TCP 443 to `login.microsoftonline.com` and `graph.microsoft.com`.
- Places a **Download Microsoft Entra Connect** shortcut on the public desktop.

### 6.2 Installation

Manual, with the wizard on DC01. The settings are in the [Quick Start](quick-start.md#4-install-microsoft-entra-connect-sync). The lab uses **Express settings**:

- Password Hash Synchronization.
- The whole `lab.contoso.com` domain is synced, including `labadmin`.
- The AD DS connector account is created by the wizard with the Enterprise Admin credentials (`LAB\labadmin`).

If the UPN suffix isn't a verified domain in the tenant, the users get a `@<tenant>.onmicrosoft.com` UPN in Entra ID. This doesn't affect Azure Files, which maps users by their on-premises SID.

### 6.3 Verify

On DC01:

```powershell
Get-ADSyncScheduler | Select-Object SyncCycleEnabled, SyncCycleInProgress, NextSyncCycleStartTimeInUTC
Get-ADSyncConnector | Select-Object Name, Type
Start-ADSyncSyncCycle -PolicyType Delta
```

> If `Get-ADSyncScheduler` isn't recognized, open a new PowerShell window, or import the module from its path: `Import-Module 'C:\Program Files\Microsoft Azure AD Sync\Bin\ADSync\ADSync.psd1'`.

On your workstation, the synced users with their on-premises SID (the `az ad user` commands don't return it):

```powershell
az rest --method get --url "https://graph.microsoft.com/v1.0/users" `
  --uri-parameters "`$filter=startswith(userPrincipalName,'LabUser')" "`$select=userPrincipalName,onPremisesSamAccountName,onPremisesSecurityIdentifier,createdDateTime" `
  --query "value[].{upn:userPrincipalName, sam:onPremisesSamAccountName, sid:onPremisesSecurityIdentifier, created:createdDateTime}" -o table
```

## 7. Azure Files

**Module:** `modules/storage.bicep`

### 7.1 Storage account

| Setting | Value |
|---|---|
| Kind / SKU | StorageV2, Standard_LRS |
| Public network access | Disabled |
| Network rules | Default action Deny, bypass AzureServices |
| Minimum TLS | 1.2, HTTPS only |
| Blob public access | Disabled |
| Shared key access | Enabled (needed for the administrative ACL mount) |

### 7.2 SMB settings

| Setting | Value |
|---|---|
| SMB versions | SMB 3.0, SMB 3.1.1 |
| Authentication methods | NTLMv2, Kerberos |
| Kerberos ticket encryption | AES-256 |
| Channel encryption | AES-128-GCM, AES-256-GCM |
| Share soft delete | 7 days |

AD DS identities can only authenticate with Kerberos. NTLMv2 works only with the storage account key.

### 7.3 File share

`fileshare`, TransactionOptimized tier, 100 GiB quota (parameters `fileShareName` and `fileShareQuotaGiB`), SMB protocol.

### 7.4 Private endpoint and DNS

- Private endpoint `pe-fileslab-file` in `snet-private-endpoints`, sub-resource `file`.
- Private DNS zone `privatelink.file.core.windows.net` linked to the VNet, with a DNS zone group on the private endpoint that maintains the A record.
- Name resolution path: CLIENT01 → DC01 (VNet DNS) → forwarder `168.63.129.16` → private DNS zone → `10.10.3.x`.
- Endpoints use `environment()`, so the template works in other Azure clouds.

**Verify** from CLIENT01:

```powershell
Resolve-DnsName <storage-account>.file.core.windows.net
Test-NetConnection <storage-account>.file.core.windows.net -Port 445
```

## 8. Storage account AD DS join

**Module:** `modules/filesAdJoin.bicep`. **Script:** `Join-StorageAccountToAD.ps1`, run on DC01.

### 8.1 How it works

1. The DC's managed identity gets **Storage Account Contributor** on the storage account only.
2. The script gets a token from the managed identity (IMDS) and retries while the role assignment propagates (up to 15 minutes).
3. It regenerates the storage account key **kerb1** and reads it.
4. It creates the computer object `stfiles<random>` in `OU=LabComputers`:
   - SPN `cifs/<storage-account>.file.core.windows.net`
   - Kerberos encryption AES-256 only
   - Password = kerb1
5. It enables AD DS authentication on the storage account with the domain name, NetBIOS name, forest, domain GUID, domain SID, the computer object's SID, its `sAMAccountName` and account type `Computer`.
6. It sets the default share-level permission (parameter `defaultSharePermission`).

If the account is already joined to this domain with the same computer object, the script only updates the default share-level permission, without rotating kerb1. That makes it safe to rerun, and useful to switch the default permission:

```powershell
$saId = az storage account show -g $rg -n $sa --query id -o tsv

az vm run-command invoke -g $rg -n vm-dc01 --command-id RunPowerShellScript `
  --scripts "@scripts/Join-StorageAccountToAD.ps1" `
  --parameters "StorageAccountId=$saId" "OuPath=OU=LabComputers,DC=lab,DC=contoso,DC=com" "DefaultSharePermission=StorageFileDataSmbShareContributor" `
  --query "value[0].message" -o tsv
```

### 8.2 Verify

```powershell
az storage account show -g $rg -n $sa --query azureFilesIdentityBasedAuthentication
```

On DC01:

```powershell
Get-ADComputer <storage-account> -Properties ServicePrincipalNames, msDS-SupportedEncryptionTypes |
  Select-Object Name, DistinguishedName, ServicePrincipalNames, msDS-SupportedEncryptionTypes
```

`msDS-SupportedEncryptionTypes` = `16` means AES-256 only.

The full check is `Debug-AzStorageAccountAuth` on CLIENT01 (see [Validation](#11-validation)): `CheckADObjectPasswordIsCorrect` confirms that the computer object's password matches kerb1.

## 9. Client

**Module:** `modules/clientVM.bicep`. VM `vm-client01`, Windows Server 2022, static private IP `10.10.2.10`.

### 9.1 Domain join

`JsonADDomainExtension` joins `lab.contoso.com` with `LAB\labadmin`, in `OU=LabComputers`, and restarts. The client module waits for the whole DC module, so the domain and the OU exist.

### 9.2 Preparation (`Prepare-Client.ps1`)

- Adds `LAB\FileShare-Users` and `LAB\FileShare-Admins` to the local **Remote Desktop Users** group, so the lab users can sign in through Bastion. Domain users who aren't local admins can't sign in remotely otherwise.
- Installs the Active Directory PowerShell module.
- Installs **AzFilesHybrid** from the PowerShell Gallery for all users, with its Az and Microsoft Graph dependencies. It provides `Debug-AzStorageAccountAuth`.

### 9.3 Windows ACLs (`Set-ShareAcl.ps1`)

See [NTFS permissions](#103-ntfs-permissions).

### 9.4 Verify

On CLIENT01:

```powershell
(Get-CimInstance Win32_ComputerSystem).Domain
Test-ComputerSecureChannel
nltest /dsgetdc:lab.contoso.com
Get-LocalGroupMember 'Remote Desktop Users'
Get-Module -ListAvailable AzFilesHybrid
```

> `dsregcmd /status` shows `AzureAdJoined: NO` on CLIENT01. That's expected: AD DS authentication for Azure Files needs AD DS domain membership, not Microsoft Entra join.

## 10. Authorization model

Access to the share goes through two layers. Both must allow the operation.

| Layer | Configured with | Checked when | Lab configuration |
|---|---|---|---|
| **Share-level permission** | Azure RBAC on the share, or the default share-level permission | The share is **mounted** (SMB tree connect) | `FileShare-Users`: Storage File Data SMB Share Contributor. `FileShare-Admins`: Storage File Data SMB Share Elevated Contributor |
| **NTFS permissions** | Windows ACLs on files and folders | A file or folder is **opened** | `FileShare-Users`: Modify. `FileShare-Admins`: Full Control |

The storage account key bypasses both layers. It's used only for the administrative ACL configuration.

### 10.1 Share-level RBAC (`Set-ShareRbac.ps1`)

Run from your workstation after Entra Connect has synced the groups. For each group, the script:

1. Reads the **domain SID of the current forest** from the storage account's AD DS settings.
2. Waits until a synced group with that name **and a SID from that domain** exists in Entra ID. Groups with the same name from previous lab forests are ignored.
3. Assigns the role at the share scope, if it isn't assigned yet.

Share-level RBAC is evaluated against the user's synced Entra ID identity, matched by the on-premises SID. Users must be synced, which is why Entra Connect is a required step.

**Verify:**

```powershell
$scope = az storage share-rm show -g $rg --storage-account $sa --name fileshare --query id -o tsv
az role assignment list --scope $scope --query "[].{principal:principalName, role:roleDefinitionName}" -o table
```

### 10.2 Default share-level permission

Parameter `defaultSharePermission`, applied by the join script:

| Value | Effect |
|---|---|
| `None` (default) | Access only through RBAC |
| `StorageFileDataSmbShareReader` | Every authenticated AD DS identity can read |
| `StorageFileDataSmbShareContributor` | Every authenticated AD DS identity can read and write |
| `StorageFileDataSmbShareElevatedContributor` | Every authenticated AD DS identity can also change NTFS permissions |

The default permission also applies to identities that aren't synced to Entra ID, including computer accounts, which can't get RBAC roles. When both apply, the user gets the higher permission.

### 10.3 NTFS permissions

`Set-ShareAcl.ps1` runs on CLIENT01 during the deployment:

1. Mounts the share with the storage account key (`/user:Azure\<storage-account>`). The key is a protected Run Command parameter, read from the storage account by Bicep, and never written to disk.
2. Grants on the share root, inherited by files and folders:

   ```powershell
   icacls \\<storage-account>.file.core.windows.net\fileshare /grant:r "LAB\FileShare-Users:(OI)(CI)M"
   icacls \\<storage-account>.file.core.windows.net\fileshare /grant:r "LAB\FileShare-Admins:(OI)(CI)F"
   ```

3. Removes the key connection.

| Flag | Meaning |
|---|---|
| `(OI)` | Files inherit the entry |
| `(CI)` | Folders inherit the entry |
| `M` | Modify |
| `F` | Full Control |

The default entries of a new share are kept, including `Authenticated Users` with Modify. To reproduce a scenario where NTFS restricts access, remove that entry while connected with the key, or as a member of `FileShare-Admins`.

**Verify** (output of the deployment step):

```powershell
az vm run-command show --name set-share-acl --vm-name vm-client01 -g $rg --expand instanceView --query instanceView.output -o tsv
```

## 11. Validation

### 11.1 Smoke test

`Test-FileShareAccess.ps1` runs on CLIENT01 as `LAB\LabUser1`, started from your workstation (see the [Quick Start](quick-start.md#6-validate)). It checks DNS, TCP 445, the mount without a key, a file write and read, and the Kerberos ticket.

Because Azure Files accepts AD DS identities only with Kerberos, a successful mount confirms the whole chain: DNS, private endpoint, domain join, storage account join, Kerberos, sync and RBAC.

### 11.2 Manual validation

Sign in to CLIENT01 through Bastion as `LabUser1@lab.contoso.com`:

```powershell
$sa = '<storage-account>'
Resolve-DnsName "$sa.file.core.windows.net"                      # 10.10.3.x
Test-NetConnection "$sa.file.core.windows.net" -Port 445          # TcpTestSucceeded: True
klist purge
net use Z: "\\$sa.file.core.windows.net\fileshare"
klist | Select-String 'Server:'                                   # cifs/<sa>.file.core.windows.net
Get-SmbConnection | Select-Object ServerName, ShareName, UserName, Dialect
whoami /user                                                      # on-premises SID
```

### 11.3 Debug-AzStorageAccountAuth

On CLIENT01, in the session of the user to check (AzFilesHybrid is installed by `Prepare-Client.ps1`):

```powershell
Connect-AzAccount -UseDeviceAuthentication -Tenant <tenant-id>
Debug-AzStorageAccountAuth -StorageAccountName <storage-account> -ResourceGroupName <rg> -Verbose
```

| Check | What it confirms |
|---|---|
| `CheckPort445Connectivity` | TCP 445 to the storage account |
| `CheckDomainJoined`, `CheckDomainLineOfSight` | The client is domain-joined and reaches a DC |
| `CheckADObject` | The storage account's computer object exists |
| `CheckGetKerberosTicket` | A ticket for `cifs/<storage-account>...` can be obtained |
| `CheckKerberosTicketEncryption` | Client and storage account agree on AES-256 |
| `CheckChannelEncryption` | SMB channel encryption ciphers match. Needs an **elevated** session |
| `CheckADObjectPasswordIsCorrect` | The computer object's password matches kerb1 |
| `CheckSidHasAadUser` | The user's on-premises SID maps to an Entra ID user |
| `CheckUserRbacAssignment` | The user has a share-level role (directly or through a group) |
| `CheckDefaultSharePermission` | Shows the default share-level permission |

## 12. Troubleshooting and lessons learned

### 12.1 Quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `RequestDisallowedByAzure`: region not accepting new customers | Capacity restriction in the region | Use another region in `main.bicepparam` (the lab uses North Europe) |
| Network deployment fails with `AnotherOperationInProgress` | Subnets deployed as separate resources | Subnets are declared inline in `network.bicep` |
| `BCP258`: parameters missing an assignment | Environment variable not set | Set all `FILESLAB_*` variables in the current PowerShell window |
| `configure-ad` interrupted | Run Command started before the post-promotion restart | Increase `rebootWaitSeconds` |
| `wait-for-vm-dc01-reboot` fails | `Microsoft.ContainerInstance` not registered, or a policy denies shared key access | Register the provider, or review the policy |
| `join-storage-ad` returns 403 for a long time | Role assignment for the DC identity not applied | The script retries 15 minutes. Check that the deploying account can create role assignments |
| Storage account resolves to a public IP | No DNS forwarder on DC01 | `Get-DnsServerForwarder` must show `168.63.129.16` |
| Bastion: "Log in failed" | Wrong user name format, or no remote sign-in right | Use `<user>@lab.contoso.com`. Lab users need Remote Desktop Users (set by `Prepare-Client.ps1`) |
| `az` errors with `expected one argument` | Variables empty in a new PowerShell window | Set `$rg`, `$sa` and the `FILESLAB_*` variables again |
| `Set-ShareRbac.ps1`: group not found | Groups not synced yet | Run `Start-ADSyncSyncCycle -PolicyType Delta` on DC01 and rerun |
| `net use`: "The password is invalid", then a credentials prompt | The share refused access after Kerberos authentication | See [12.2](#122-the-password-is-invalid-when-mounting) |
| Mount: System error 5 | No share-level permission for the user, or identities colliding with leftovers of a previous forest | Check RBAC at the share scope and the default permission. See [12.3](#123-leftover-objects-from-previous-lab-forests) |
| Mount: System error 1326 | NTLM fallback with typed credentials | Don't type credentials at the prompt. AD DS identities only work with Kerberos |
| Mount: System error 1219 | A connection to the same server with other credentials exists | `net use * /delete /y` |
| `Get-ADSyncScheduler` not recognized | ADSync module not loaded in the session | Open a new window, or import it from `C:\Program Files\Microsoft Azure AD Sync\Bin\ADSync\ADSync.psd1` |
| `CheckChannelEncryption` fails in `Debug-AzStorageAccountAuth` | Session not elevated | Run elevated, or check `Get-SmbClientConfiguration` from an elevated session |

### 12.2 "The password is invalid" when mounting

```text
PS> net use Z: \\<storage-account>.file.core.windows.net\fileshare
The password is invalid for \\<storage-account>.file.core.windows.net\fileshare.
Enter the user name for '<storage-account>.file.core.windows.net':
```

The message is misleading. Windows shows it when the share refuses the connection, and then offers to try other credentials. Typed credentials fall back to NTLM, which Azure Files doesn't accept for AD DS identities, so they end in System error 5 or 1326.

The SMB client log on the client shows the real status:

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-SMBClient/Security' -MaxEvents 5 | Format-List TimeCreated, Id, Message
```

- Event **31010** with **Access Denied** at "connect to the share": Kerberos worked, and the **share-level permission** refused the user.
- A logon failure status: the storage account rejected the authentication itself. Check the join with `Debug-AzStorageAccountAuth`.

To tell authentication and authorization apart quickly, temporarily set a default share-level permission (see [8.1](#81-how-it-works)). If the mount then works, Kerberos and the join are fine and the problem is the user's share-level permission.

### 12.3 Leftover objects from previous lab forests

Each deployment creates a new forest with new SIDs, but the same names: `LabUser1`, `FileShare-Users`, `labadmin`. If a previous lab was deleted while its objects were synced, they stay in Entra ID as orphaned synced objects. While directory synchronization is enabled on the tenant, they can't be edited or deleted.

Effects on the next deployment:

- **Duplicate groups:** two synced `FileShare-Users` groups. `Set-ShareRbac.ps1` handles this by selecting the group whose SID belongs to the current forest.
- **Renamed users:** the new users conflict with the old ones' UPN, so Entra Connect gives them a generated UPN, for example `LabUser15881@<tenant>.onmicrosoft.com`. Their on-premises SID is still correct.
- **Share-level RBAC can fail:** observed in testing. After a redeployment into a tenant that still had the orphaned objects of a previous forest with the **same domain name and user names**:
  - Kerberos worked, and `Debug-AzStorageAccountAuth` passed every check, including `CheckSidHasAadUser` (mapped to the renamed user) and `CheckUserRbacAssignment`.
  - The mount was still denied (event 31010, Access Denied) with RBAC only, both through the group role and with the role assigned directly to the user, for hours.
  - With a default share-level permission, the same user mounted immediately.

  The duplicate identities are the most likely cause, but this wasn't confirmed. A previous deployment in the same tenant, without leftovers, worked with group RBAC.

How to avoid it:

1. Before deleting a lab, run `Remove-LabSyncedObjects.ps1` on DC01 and purge the deleted users (see the [Quick Start](quick-start.md#7-clean-up)).
2. With Express settings, the whole domain is synced. The cleanup script also removes `labadmin` (parameter `AdditionalUsers`), but other objects outside the lab OUs stay. Use **Customize** with OU filtering on `LabUsers` and `LabGroups` to sync only the lab objects.
3. If the tenant already has leftovers, deploy the new lab with a **different domain**: change `domainName` and `netbiosName` in `main.bicepparam` (for example `lab2.contoso.com` and `LAB2`). The new identities then can't collide with the old ones.
4. As a workaround, set a default share-level permission (see [10.2](#102-default-share-level-permission)).
5. To remove orphaned objects for good, turn off directory synchronization for the tenant (this can take up to 72 hours), delete them, and let the next Entra Connect installation turn it on again.

### 12.4 Windows PowerShell 5.1 and native commands

With `$ErrorActionPreference = 'Stop'`, Windows PowerShell 5.1 turns anything a native command (`net`, `klist`, `icacls`) writes to stderr into a terminating error when it's redirected with `2>&1`. The lab scripts set `Continue` before native commands and check `$LASTEXITCODE` instead.

### 12.5 Azure CLI notes

| Command | Note |
|---|---|
| `az vm run-command show` | Use `--name` (no `-n`) and `--expand instanceView`. `--expand` shows a deprecation warning, which is harmless |
| `az ad user list --filter "onPremisesSamAccountName eq ..."` | Not supported. Use the Microsoft Graph query in [6.3](#63-verify) |
| `az ad user list` | Doesn't return `onPremisesSecurityIdentifier`. Use Microsoft Graph with `$select` |
| `az ad group list` | Returns `onPremisesSecurityIdentifier` and `onPremisesSyncEnabled` |
| `az rest` with `&` in the URL | On Windows, `az` is a batch file and `&` splits the command (`'$select' is not recognized`). Pass query options with `--uri-parameters` instead |

## 13. Security considerations

This lab is for testing and learning. It isn't a production design.

- **Entra Connect Sync on a Domain Controller** combines sensitive identity components on one server. Use a dedicated server in production.
- **Lab passwords** are passed as environment variables and protected Run Command parameters. Use unique passwords, and don't reuse them outside the lab.
- **Storage account key:** used only for the ACL configuration, passed as a protected parameter, never stored in the repository, on the VM or in the output. Rotate it if you suspect exposure.
- **DC managed identity:** Storage Account Contributor scoped to the lab storage account only.
- **No public IPs:** the VMs are reachable only through Azure Bastion, and the storage account only through its private endpoint.
- **Test tenant only:** Entra Connect syncs the lab users and groups. Never connect the lab to a production or corporate tenant.

In production:

- Minimize storage account key use, and keep secrets in Azure Key Vault.
- Make administrative ACL changes with a dedicated identity in `FileShare-Admins`-style groups.
- Follow least privilege for share-level RBAC.
- Keep administrative and user permissions in separate groups.
