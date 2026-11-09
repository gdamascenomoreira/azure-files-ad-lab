# Quick Start: Automated Deployment

This guide deploys a lab to reproduce Azure Files scenarios with on-premises AD DS authentication, as customers run them:

- An on-premises Active Directory, simulated with an Azure VM
- Microsoft Entra Connect Sync, synchronizing the lab users and groups to Microsoft Entra ID
- An Azure file share behind a private endpoint, joined to AD DS
- Share-level permissions through Azure RBAC on the synced groups
- A domain-joined client that mounts the share with Kerberos

Almost everything is deployed with a single Bicep deployment. The only manual step is the Microsoft Entra Connect Sync wizard: Microsoft supports its installation only through the wizard, and the installer can only be downloaded from the Microsoft Entra admin center.

For a step-by-step explanation of every component, see the [Deployment Guide](deployment-guide.md).

## Overview

| Step | What | How | Time |
|---|---|---|---|
| 1 | Prerequisites | Once | |
| 2 | Get the code and set the secrets | Manual | 2 min |
| 3 | Deploy the infrastructure | Bicep (automated) | XX min |
| 4 | Install Microsoft Entra Connect Sync | Wizard on DC01 (manual) | ~15 min |
| 5 | Assign share-level permissions | Script (automated) | XX min |
| 6 | Validate | Script (automated) | 2 min |
| 7 | Clean up | Scripts (automated) | XX min |

## What gets deployed

| Component | Resource | Details |
|---|---|---|
| Network | `vnet-fileslab` | Subnets for DC, client and private endpoint. VNet DNS points to DC01 |
| Domain Controller | `vm-dc01` (DC01) | New forest `lab.contoso.com`, DNS forwarder to Azure DNS, lab OUs, groups and users, ready for Entra Connect |
| Storage | `stfiles<random>` | Azure file share `fileshare`, private endpoint, private DNS zone |
| AD DS join | Run Command on DC01 | Storage account computer object (AES-256), AD DS authentication enabled |
| Client | `vm-client01` (CLIENT01) | Joined to the domain in `OU=LabComputers` |

Lab identities created in AD:

| Object | OU | Notes |
|---|---|---|
| `LabUser1`, `LabUser2` | `LabUsers` | Members of `FileShare-Users` |
| `FileShare-Users` | `LabGroups` | Gets *Storage File Data SMB Share Contributor* |
| `FileShare-Admins` | `LabGroups` | Gets *Storage File Data SMB Share Elevated Contributor* |

Deployment order:

```
network ──┬── DC VM → install AD DS → promote → wait for reboot → configure AD → prepare Entra Connect ──┬── client VM + domain join
          │                                                                                            └── storage AD DS join
          └── storage account + private endpoint ──────────────────────────────────────────────────────────┘
```

## 1. Prerequisites

### Microsoft Entra tenant and subscription

- A **test Microsoft Entra tenant** where you are **Global Administrator** or **Hybrid Identity Administrator**. Don't use a production or corporate tenant.
- An **Azure subscription in that same tenant**. Share-level RBAC can only be assigned to identities of the tenant that owns the subscription, so Entra Connect must sync to that tenant.
- Optional: a **verified custom domain** in the tenant, used as the UPN suffix of the lab users. Without it, the synced users get a `@<tenant>.onmicrosoft.com` UPN in Entra ID, which doesn't affect Azure Files.

### Azure permissions and quota

- **Owner**, or **Contributor** plus **User Access Administrator**, on the subscription or resource group. The deployment and the RBAC script create role assignments.
- Quota for **4 vCPUs** of the Dsv5 family in the target region (two `Standard_D2s_v5` VMs).

### Tools

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.53 or later, with Bicep:

  ```powershell
  az bicep install
  ```

- Sign in to the **test tenant** and select its subscription:

  ```powershell
  az login --tenant "<test-tenant-id>"
  az account set --subscription "<subscription-id>"
  ```

- Register the resource providers:

  ```powershell
  foreach ($rp in 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.ContainerInstance') {
      az provider register --namespace $rp
  }
  ```

> `Microsoft.ContainerInstance` is used by a short deployment script that waits for the DC restart after promotion. It also creates a temporary storage account with key access, which is deleted at the end. If your subscription has a policy that denies shared key access on storage accounts, that step will fail.

### Access to the VMs

The VMs have no public IP. The Entra Connect wizard needs a desktop session on DC01, through **Azure Bastion**. The template doesn't deploy Bastion: in the Azure portal, open `vm-dc01` > **Connect** > **Bastion** and deploy it from there (the Developer SKU is free).

## 2. Get the code and set the secrets

```powershell
git clone https://github.com/gdamascenomoreira/azure-files-ad-lab.git
cd azure-files-ad-lab
```

Secrets are read from environment variables, so they are never stored in the repository.

Use at least 12 characters with uppercase, lowercase, digits and a symbol. Avoid quotes, spaces and `$`, because the values are passed to scripts as Run Command parameters.

```powershell
$env:FILESLAB_VM_PASSWORD      = '<DC01 admin password, also the domain admin and domain join password>'
$env:FILESLAB_CLIENT_PASSWORD  = '<CLIENT01 local admin password>'
$env:FILESLAB_DSRM_PASSWORD    = '<Directory Services Restore Mode password>'
$env:FILESLAB_LABUSER_PASSWORD = '<LabUser1 and LabUser2 password>'

# Optional: verified custom domain of the test tenant
# $env:FILESLAB_UPN_SUFFIX = 'contoso.com'
```

| Variable | Required | Used for |
|---|---|---|
| `FILESLAB_VM_PASSWORD` | Yes | DC01 `labadmin`, which becomes `LAB\labadmin` (Domain Admin and Enterprise Admin) and joins CLIENT01 to the domain |
| `FILESLAB_CLIENT_PASSWORD` | Yes | CLIENT01 local `clientadmin` |
| `FILESLAB_DSRM_PASSWORD` | Yes | DSRM password set during promotion |
| `FILESLAB_LABUSER_PASSWORD` | Yes | `LabUser1` and `LabUser2` |
| `FILESLAB_UPN_SUFFIX` | No | UPN suffix for the lab users. Empty uses `lab.contoso.com` |

## 3. Deploy the infrastructure

```powershell
$rg = 'rg-fileslab'

az group create --name $rg --location northeurope

# Preview the changes
az deployment group what-if --resource-group $rg --name fileslab --parameters main.bicepparam

# Deploy
az deployment group create --resource-group $rg --name fileslab --parameters main.bicepparam
```

The deployment takes about **XX minutes**.

At the end, DC01 is ready for Entra Connect: TLS 1.2 is enabled, IE Enhanced Security Configuration is off, the prerequisites are checked, and a **Download Microsoft Entra Connect** shortcut is on the desktop. To see the prerequisite checks:

```powershell
az vm run-command show -g $rg --vm-name vm-dc01 -n prepare-entra-connect --instance-view --query instanceView.output -o tsv
```

### Main parameters

All parameters have defaults in `main.bicepparam`.

| Parameter | Default | Description |
|---|---|---|
| `location` | `northeurope` | Azure region |
| `domainName` | `lab.contoso.com` | AD DS forest root domain |
| `netbiosName` | `LAB` | NetBIOS name of the domain |
| `dcVmSize` / `clientVmSize` | `Standard_D2s_v5` | VM sizes |
| `fileShareName` | `fileshare` | Azure file share name |
| `fileShareQuotaGiB` | `100` | Share quota |
| `defaultSharePermission` | `None` | Share-level permission for every authenticated AD DS identity. `None` means access only through RBAC on the synced groups. Set a role (for example `StorageFileDataSmbShareContributor`) to repro scenarios that use a default share-level permission |

> The storage account name is limited to 15 characters because it becomes an AD computer name. The default is `stfiles` plus 8 random characters.

## 4. Install Microsoft Entra Connect Sync

1. Connect to **DC01** through Azure Bastion as `labadmin@lab.contoso.com`.

   > Bastion needs the domain account in UPN format. `LAB\labadmin` doesn't work.

2. Open the **Download Microsoft Entra Connect** shortcut on the desktop, sign in with your **test tenant** admin account and download the latest version.

   If the shortcut doesn't open the right page: Microsoft Entra admin center > **Identity** > **Hybrid management** > **Microsoft Entra Connect** > **Get started** > **Manage** tab > **Download**.

3. Run `AzureADConnect.msi` and go through the wizard with these settings:

   | Page | Setting |
   |---|---|
   | Express Settings | **Customize** |
   | Install required components | Defaults > **Install** |
   | User sign-in | **Password Hash Synchronization** |
   | Connect to Microsoft Entra ID | Your test tenant admin account |
   | Connect your directories | Forest `lab.contoso.com` > **Add Directory** > **Create new AD account** with `LAB\labadmin` |
   | Microsoft Entra sign-in configuration | If you didn't set a verified UPN suffix, select **Continue without matching all UPN suffixes to verified domains** |
   | Domain and OU filtering | **Sync selected domains and OUs**: select only **LabUsers** and **LabGroups** |
   | Uniquely identifying your users | Defaults |
   | Filter users and devices | **Synchronize all users and devices** |
   | Optional features | Defaults |
   | Ready to configure | Keep **Start the synchronization process when configuration completes** > **Install** |

> **Why OU filtering:** only the lab objects are synced. Each deployment creates a new forest, and objects outside these OUs (for example `labadmin`) would otherwise stay in Entra ID after the lab is destroyed. See [Clean up](#7-clean-up).

The first sync starts when the wizard finishes. To check it on DC01:

```powershell
Get-ADSyncScheduler | Select-Object SyncCycleEnabled, SyncCycleInProgress, NextSyncCycleStartTimeInUTC
```

## 5. Assign share-level permissions

From your workstation, assign the RBAC roles to the synced groups:

```powershell
./scripts/Set-ShareRbac.ps1 -ResourceGroupName $rg
```

| Group | Role |
|---|---|
| `FileShare-Users` | Storage File Data SMB Share Contributor |
| `FileShare-Admins` | Storage File Data SMB Share Elevated Contributor |

The script waits for the groups to appear in Entra ID (up to 40 minutes), only uses groups synced from AD, and can be run again safely. If it finds two synced groups with the same name, the objects of a previous deployment weren't cleaned up (see [Clean up](#7-clean-up)).

## 6. Validate

Run the smoke test on CLIENT01 as `LAB\LabUser1`:

```powershell
$sa = az deployment group show -g $rg -n fileslab --query properties.outputs.storageAccountName.value -o tsv

az vm run-command create -g $rg --vm-name vm-client01 --name smoke-test `
  --script "@scripts/Test-FileShareAccess.ps1" `
  --parameters "StorageAccountName=$sa" "UserName=LAB\LabUser1" `
  --protected-parameters "Password=$env:FILESLAB_LABUSER_PASSWORD" `
  --async-execution false

az vm run-command show -g $rg --vm-name vm-client01 --name smoke-test --instance-view --query instanceView.output -o tsv
```

Expected result:

```
Testing \\stfilesxxxxxxxx.file.core.windows.net\fileshare as LAB\LabUser1
[PASS] DNS: stfilesxxxxxxxx.file.core.windows.net -> 10.10.3.x
[PASS] TCP 445: stfilesxxxxxxxx.file.core.windows.net (10.10.3.x)
[PASS] Mount: The command completed successfully.
[PASS] Write file: \\stfilesxxxxxxxx.file.core.windows.net\fileshare\smoke-test-LAB_LabUser1.txt
...
All checks passed.
```

Azure Files accepts AD DS identities only over Kerberos (NTLM works only with the storage account key), so a successful mount with `LabUser1` confirms DNS, the private endpoint, the domain join, the storage account AD DS join, Kerberos and the RBAC role of `FileShare-Users`.

> Right after `Set-ShareRbac.ps1`, the mount can fail with **System error 5 (access denied)** while the role assignment is applied. Wait a few minutes and run the test again.

To test interactively, connect to CLIENT01 through Bastion as `LabUser1@lab.contoso.com` and run:

```powershell
net use Z: \\<storage-account>.file.core.windows.net\fileshare
klist
```

## 7. Clean up

Clean the tenant **before** deleting the resource group. Each deployment creates a new forest, so synced objects left behind would conflict with the next deployment.

**1. Delete the lab users and groups in AD and sync the deletions to Entra ID:**

```powershell
az vm run-command invoke -g $rg -n vm-dc01 --command-id RunPowerShellScript `
  --scripts "@scripts/Remove-LabSyncedObjects.ps1" `
  --query "value[0].message" -o tsv
```

**2. Purge the deleted users from the Entra ID recycle bin** (security groups are deleted permanently right away):

```powershell
$deleted = az rest --method get `
  --url 'https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user?$select=id,userPrincipalName' `
  --query "value[?contains(userPrincipalName, 'LabUser')].id" -o tsv

foreach ($id in $deleted) {
    az rest --method delete --url "https://graph.microsoft.com/v1.0/directory/deletedItems/$id"
}
```

**3. Delete the resource group:**

```powershell
az group delete --name $rg --yes --no-wait
```

> **If the lab was deleted without step 1**, the synced objects stay in Entra ID and can't be edited or deleted while directory synchronization is enabled on the tenant. To remove them, turn off directory synchronization for the tenant (it can take up to 72 hours to complete), delete the objects, and the next Entra Connect installation turns it on again.

## Deployment times

Measured on a deployment from scratch in `northeurope`.

| Step | Duration |
|---|---|
| Network | |
| DC VM | |
| Install AD DS | |
| Promote to DC | |
| Wait for restart | |
| Configure AD | |
| Prepare Entra Connect | |
| Storage account and private endpoint | |
| Storage account AD DS join | |
| Client VM and domain join | |
| **Infrastructure total (step 3)** | |
| Entra Connect wizard and first sync (step 4) | |
| Groups synced and RBAC assigned (step 5) | |
| **Ready to repro** | |

To get the durations of the infrastructure deployment:

```powershell
# Total
az deployment group show -g $rg -n fileslab --query properties.duration -o tsv

# Per module
az deployment operation group list -g $rg -n fileslab `
  --query "[?properties.targetResource.resourceName!=null].{step:properties.targetResource.resourceName, duration:properties.duration, state:properties.provisioningState}" -o table

# Inside the DC module
az deployment operation group list -g $rg -n domainControllerDeployment `
  --query "[].{step:properties.targetResource.resourceName, duration:properties.duration}" -o table
```

Durations use the ISO 8601 format, for example `PT27M14S` is 27 minutes and 14 seconds.

## Troubleshooting

**Find the failed step**

```powershell
az deployment operation group list -g $rg -n fileslab `
  --query "[?properties.provisioningState=='Failed'].{step:properties.targetResource.resourceName, error:properties.statusMessage.error.message}" -o table
```

**Read a Run Command output**

| Run Command | VM | Script |
|---|---|---|
| `install-adds` | `vm-dc01` | `Install-ADDS.ps1` |
| `promote-dc` | `vm-dc01` | `Promote-DC.ps1` |
| `configure-ad` | `vm-dc01` | `Configure-ADLab.ps1` |
| `prepare-entra-connect` | `vm-dc01` | `Prepare-EntraConnect.ps1` |
| `join-storage-ad` | `vm-dc01` | `Join-StorageAccountToAD.ps1` |
| `smoke-test` | `vm-client01` | `Test-FileShareAccess.ps1` |

```powershell
az vm run-command show -g $rg --vm-name vm-dc01 -n configure-ad --instance-view --query instanceView
```

**Common issues**

| Symptom | Cause | Fix |
|---|---|---|
| Network deployment fails with `AnotherOperationInProgress` | Old version of `network.bicep` with subnets as separate resources | Update to the current version (subnets declared inline) |
| `configure-ad` fails or is interrupted | Run Command started before the post-promotion restart | Increase `rebootWaitSeconds` in `modules/domainController.bicep` |
| `prepare-entra-connect` fails | A prerequisite check failed | Read its output: each check shows PASS or FAIL |
| `join-storage-ad` returns 403 for a long time | Role assignment for the DC managed identity not applied yet | The script retries for 15 minutes. Check that the deploying account can create role assignments |
| Client domain join fails | DC not ready or DNS not pointing to DC01 | Check the `configure-ad` output and the VNet DNS servers |
| DNS check returns a public IP | DC01 has no forwarder to Azure DNS | `Get-DnsServerForwarder` on DC01 should show `168.63.129.16` |
| Bastion sign-in to DC01 fails | Domain account not in UPN format | Use `labadmin@lab.contoso.com` |
| `Set-ShareRbac.ps1` finds no group | Groups not synced, or not in the sync scope | Check OU filtering (LabGroups selected) and run `Start-ADSyncSyncCycle -PolicyType Delta` on DC01 |
| `Set-ShareRbac.ps1` finds two groups with the same name | Objects of a previous deployment not cleaned up | Delete the old groups in Entra ID, see [Clean up](#7-clean-up) |
| Mount fails with System error 5 | No share-level permission for the user | Check the RBAC roles at the share scope, wait a few minutes after assigning them |
| Deployment fails on `wait-for-vm-dc01-reboot` | `Microsoft.ContainerInstance` not registered, or policy blocks shared key access | Register the provider, or check the policy assignments |

## Repository structure

```
azure-files-ad-lab/
├── main.bicep                         # Orchestrates all modules
├── main.bicepparam                    # Parameters (secrets from environment variables)
├── modules/
│   ├── network.bicep                  # VNet, subnets, NSG, DNS servers
│   ├── domainController.bicep         # DC01 + AD DS and Entra Connect preparation Run Commands
│   ├── storage.bicep                  # Storage account, file share, private endpoint, DNS zone
│   ├── filesAdJoin.bicep              # Role assignment + storage account AD DS join
│   └── clientVM.bicep                 # CLIENT01 + domain join
├── scripts/
│   ├── Install-ADDS.ps1               # Installs the AD DS role
│   ├── Promote-DC.ps1                 # Creates the forest
│   ├── Configure-ADLab.ps1            # DNS forwarder, UPN suffix, OUs, groups, users
│   ├── Prepare-EntraConnect.ps1       # TLS 1.2, IE ESC, prerequisite checks, download shortcut
│   ├── Join-StorageAccountToAD.ps1    # Storage account AD DS join + default share permission
│   ├── Set-ShareRbac.ps1              # Group RBAC at share scope (from your workstation)
│   ├── Test-FileShareAccess.ps1       # Smoke test from CLIENT01
│   └── Remove-LabSyncedObjects.ps1    # Removes the lab objects from Entra ID before clean up
└── docs/
    ├── quick-start.md                 # This guide
    └── deployment-guide.md            # Detailed guide
```
