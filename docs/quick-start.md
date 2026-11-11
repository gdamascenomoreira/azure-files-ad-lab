# Quick Start: Automated Deployment

This guide deploys a lab to reproduce Azure Files scenarios with on-premises AD DS authentication, as customers run them:

- An on-premises Active Directory, simulated with an Azure VM
- Microsoft Entra Connect Sync, synchronizing the lab users and groups to Microsoft Entra ID
- An Azure file share behind a private endpoint, joined to AD DS
- Share-level permissions through Azure RBAC on the synced groups, and NTFS permissions on the share
- A domain-joined client that mounts the share with Kerberos, with the troubleshooting tools installed

Almost everything is deployed with a single Bicep deployment. The only manual step is the Microsoft Entra Connect Sync wizard: Microsoft supports its installation only through the wizard, and the installer can only be downloaded from the Microsoft Entra admin center.

To understand how each part works, or to verify and troubleshoot it by hand, see [How It Works](deployment-guide.md).

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
| Client | `vm-client01` (CLIENT01) | Joined to the domain, lab groups allowed to sign in through Bastion, AzFilesHybrid installed |
| NTFS permissions | Run Command on CLIENT01 | `FileShare-Users` Modify and `FileShare-Admins` Full Control on the share root |

Lab identities created in AD:

| Object | OU | Share-level role | NTFS |
|---|---|---|---|
| `LabUser1`, `LabUser2` | `LabUsers` | Through `FileShare-Users` | Through `FileShare-Users` |
| `FileShare-Users` | `LabGroups` | Storage File Data SMB Share Contributor | Modify |
| `FileShare-Admins` | `LabGroups` | Storage File Data SMB Share Elevated Contributor | Full Control |

Deployment order:

```
network ──┬── DC VM → install AD DS → promote → wait for restart → configure AD → prepare Entra Connect ──┬── CLIENT01 + domain join → prepare client ──┬── NTFS permissions
          │                                                                                             └── storage AD DS join                         │
          └── storage account + file share + private endpoint ─────────────────────────────────────────────────────────────────────────────────────────┘
```

## 1. Prerequisites

### Microsoft Entra tenant and subscription

- A **test Microsoft Entra tenant** where you are **Global Administrator** or **Hybrid Identity Administrator**. Don't use a production or corporate tenant.
- An **Azure subscription in that same tenant**. Share-level RBAC can only be assigned to identities of the tenant that owns the subscription, so Entra Connect must sync to that tenant.
- Optional: a **verified custom domain** in the tenant, used as the UPN suffix of the lab users. Without it, the synced users get a `@<tenant>.onmicrosoft.com` UPN in Entra ID, which doesn't affect Azure Files.
- **No leftovers of a previous lab** in the tenant. If a previous lab was deleted without the [clean up](#7-clean-up), its synced users and groups are still in Entra ID, and share-level RBAC can fail for the new lab's users with the same names. In that case, deploy with a different domain (see [Main parameters](#main-parameters)).

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
  az account show --query "{tenant:tenantId, subscription:name}" -o table
  ```

- Register the resource providers:

  ```powershell
  foreach ($rp in 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.ContainerInstance') {
      az provider register --namespace $rp
  }
  ```

> `Microsoft.ContainerInstance` is used by a short deployment script that waits for the DC restart after promotion. It also creates a temporary storage account with key access, which is deleted at the end. If your subscription has a policy that denies shared key access on storage accounts, that step will fail.

### Access to the VMs

The VMs have no public IP. The Entra Connect wizard and interactive tests need a desktop session, through **Azure Bastion**. The template doesn't deploy Bastion: in the Azure portal, open `vm-dc01` > **Connect** > **Bastion** and deploy it from there (the Developer SKU is free).

Bastion needs domain accounts in the format `<user>@lab.contoso.com`:

| Account | Bastion user name | Can sign in to |
|---|---|---|
| Domain admin | `labadmin@lab.contoso.com` | DC01, CLIENT01 |
| Lab users | `LabUser1@lab.contoso.com` | CLIENT01 |

> Use `@lab.contoso.com` even when the lab users have a custom UPN suffix. `LAB\labadmin` doesn't work in Bastion.

## 2. Get the code and set the secrets

Run all the commands in this guide from the `azure-files-ad-lab` folder:

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

> PowerShell variables only exist in the window where you set them. If you open a new window, run `cd azure-files-ad-lab`, set the variables above again, and set `$rg` and `$sa` (sections 3 and 5).

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

At the end:

- DC01 is ready for Entra Connect: TLS 1.2 is enabled, IE Enhanced Security Configuration is off, the prerequisites are checked, and a **Download Microsoft Entra Connect** shortcut is on the desktop.
- CLIENT01 is joined to the domain, the lab groups can sign in through Bastion, and AzFilesHybrid is installed.
- The NTFS permissions are set on the share root.

To see the prerequisite checks:

```powershell
az vm run-command show --name prepare-entra-connect --vm-name vm-dc01 -g $rg --expand instanceView --query instanceView.output -o tsv
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

> **Changing the domain:** set `domainName` and `netbiosName` in `main.bicepparam` (for example `lab2.contoso.com` and `LAB2`) to avoid collisions with leftovers of a previous lab. Then use your values wherever this guide shows `lab.contoso.com` or `LAB`.

## 4. Install Microsoft Entra Connect Sync

1. Connect to **DC01** through Azure Bastion as `labadmin@lab.contoso.com`.

2. Open the **Download Microsoft Entra Connect** shortcut on the desktop, sign in with your **test tenant** admin account and download the latest version.

   If the shortcut doesn't open the right page: Microsoft Entra admin center > **Identity** > **Hybrid management** > **Microsoft Entra Connect** > **Get started** > **Manage** tab > **Download**.

3. Run `AzureADConnect.msi` and go through the wizard with **Express Settings**:

   | Page | Setting |
   |---|---|
   | Welcome | Agree to the license terms > **Continue** |
   | Express Settings | **Use express settings** |
   | Connect to Microsoft Entra ID | Your test tenant admin account (Global Administrator or Hybrid Identity Administrator) |
   | Connect to AD DS | `LAB\labadmin` and its password. Use the DOMAIN\user format here, not UPN |
   | Microsoft Entra sign-in configuration | If you didn't set a verified UPN suffix, select **Continue without matching all UPN suffixes to verified domains** |
   | Ready to configure | Keep **Start the synchronization process when configuration completes** > **Install** |

   Express settings configure Password Hash Synchronization and sync the whole `lab.contoso.com` domain.

> **Sync scope:** with Express settings, the whole domain is synced. At clean up, `Remove-LabSyncedObjects.ps1` removes the lab OUs and `labadmin`, but any other object you create outside the lab OUs stays in Entra ID. To sync only the lab objects, choose **Customize** instead and, on **Domain and OU filtering**, select only **LabUsers** and **LabGroups**. See [Clean up](#7-clean-up).

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

The script waits for the groups to appear in Entra ID (up to 40 minutes) and can be run again safely. It only uses groups synced from **this** lab's forest: groups with the same name left over from previous labs are listed as ignored.

To check the result:

```powershell
$sa = az deployment group show -g $rg -n fileslab --query properties.outputs.storageAccountName.value -o tsv
$scope = az storage share-rm show -g $rg --storage-account $sa --name fileshare --query id -o tsv
az role assignment list --scope $scope --query "[].{principal:principalName, role:roleDefinitionName}" -o table
```

## 6. Validate

Run these commands **on your workstation**. Azure CLI sends `scripts/Test-FileShareAccess.ps1` to CLIENT01 through Run Command, runs it there as `LAB\LabUser1`, and returns the result. You don't need to connect to CLIENT01.

```powershell
# Storage account name from the deployment outputs
$sa = az deployment group show -g $rg -n fileslab --query properties.outputs.storageAccountName.value -o tsv

# Run the smoke test on CLIENT01
az vm run-command create -g $rg --vm-name vm-client01 --name smoke-test `
  --script "@scripts/Test-FileShareAccess.ps1" `
  --parameters "StorageAccountName=$sa" "UserName=LAB\LabUser1" `
  --protected-parameters "Password=$env:FILESLAB_LABUSER_PASSWORD" `
  --async-execution false

# Show the result
az vm run-command show --name smoke-test --vm-name vm-client01 -g $rg --expand instanceView --query instanceView.output -o tsv
```

The test runs on CLIENT01 because the checks only make sense from inside the lab network: the storage account resolves to the private endpoint only through DC01's DNS, and port 445 is only reachable from the VNet.

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

Azure Files accepts AD DS identities only over Kerberos (NTLM works only with the storage account key), so a successful mount with `LabUser1` confirms DNS, the private endpoint, the domain join, the storage account AD DS join, Kerberos, the sync and the RBAC role of `FileShare-Users`.

> Right after `Set-ShareRbac.ps1`, the mount can fail with **System error 5 (access denied)** while the role assignment is applied. Wait a few minutes and run the test again.

### Interactive test

Connect to CLIENT01 through Bastion as `LabUser1@lab.contoso.com` and run:

```powershell
net use Z: \\<storage-account>.file.core.windows.net\fileshare
klist
```

If the mount fails, don't type credentials at the prompt (they fall back to NTLM, which can't work). Run the diagnostic from the same session instead. AzFilesHybrid is already installed on CLIENT01:

```powershell
Connect-AzAccount -UseDeviceAuthentication -Tenant "<test-tenant-id>"
Debug-AzStorageAccountAuth -StorageAccountName <storage-account> -ResourceGroupName <rg> -Verbose
```

See [Troubleshooting](deployment-guide.md#12-troubleshooting-and-lessons-learned) in How It Works for how to read the results.

## 7. Clean up

Clean the tenant **before** deleting the resource group. Each deployment creates a new forest, so synced objects left behind would conflict with the next deployment (duplicate groups, renamed users).

**1. Delete the lab users, groups and `labadmin` in AD and sync the deletions to Entra ID:**

```powershell
az vm run-command invoke -g $rg -n vm-dc01 --command-id RunPowerShellScript `
  --scripts "@scripts/Remove-LabSyncedObjects.ps1" `
  --query "value[0].message" -o tsv
```

> The script removes everything in `LabUsers` and `LabGroups`, plus `labadmin`. With Express settings, any other object you created outside these OUs stays in Entra ID as an orphaned synced object.

**2. Purge the deleted users from the Entra ID recycle bin** (security groups are deleted permanently right away):

```powershell
$deleted = az rest --method get `
  --url "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user" `
  --uri-parameters "`$select=id,userPrincipalName" `
  --query "value[?contains(userPrincipalName, 'LabUser') || contains(userPrincipalName, 'labadmin')].id" -o tsv

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
| Client VM, domain join and preparation | |
| NTFS permissions | |
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

```powershell
az vm run-command show --name <run-command> --vm-name <vm> -g $rg --expand instanceView --query instanceView.output -o tsv
```

| Run Command | VM | Script |
|---|---|---|
| `install-adds` | `vm-dc01` | `Install-ADDS.ps1` |
| `promote-dc` | `vm-dc01` | `Promote-DC.ps1` |
| `configure-ad` | `vm-dc01` | `Configure-ADLab.ps1` |
| `prepare-entra-connect` | `vm-dc01` | `Prepare-EntraConnect.ps1` |
| `join-storage-ad` | `vm-dc01` | `Join-StorageAccountToAD.ps1` |
| `prepare-client` | `vm-client01` | `Prepare-Client.ps1` |
| `set-share-acl` | `vm-client01` | `Set-ShareAcl.ps1` |
| `smoke-test` | `vm-client01` | `Test-FileShareAccess.ps1` |

> `--expand` shows a deprecation warning. It's harmless.

**Common issues**

| Symptom | Fix |
|---|---|
| `az` errors with `expected one argument` | Variables are empty in a new PowerShell window. Set `$rg`, `$sa` and the `FILESLAB_*` variables again |
| Network deployment fails with `AnotherOperationInProgress` | Update `network.bicep` to the current version (subnets declared inline) |
| `configure-ad` fails or is interrupted | Increase `rebootWaitSeconds` in `modules/domainController.bicep` |
| `prepare-entra-connect` fails | Read its output: each check shows PASS or FAIL |
| `join-storage-ad` returns 403 for a long time | The script retries for 15 minutes. Check that the deploying account can create role assignments |
| DNS check returns a public IP | `Get-DnsServerForwarder` on DC01 should show `168.63.129.16` |
| Bastion: "Log in failed" | Use `<user>@lab.contoso.com` |
| `Set-ShareRbac.ps1` finds no group | Run `Start-ADSyncSyncCycle -PolicyType Delta` on DC01 and run the script again |
| `net use`: "The password is invalid", then a credentials prompt | The share refused access. Don't type credentials. See [12.2](deployment-guide.md#122-the-password-is-invalid-when-mounting) |
| Mount fails with System error 5 | Check the RBAC roles at the share scope and wait a few minutes after assigning them. If the tenant has leftovers of a previous lab, see [12.3](deployment-guide.md#123-leftover-objects-from-previous-lab-forests) |
| `az rest`: `'$select' is not recognized` | On Windows, `&` in the URL splits the command. Use `--uri-parameters` |
| Deployment fails on `wait-for-vm-dc01-reboot` | Register `Microsoft.ContainerInstance`, or check the policy assignments |

More in [Troubleshooting and lessons learned](deployment-guide.md#12-troubleshooting-and-lessons-learned).

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
│   ├── clientVM.bicep                 # CLIENT01 + domain join + client preparation
│   └── shareAcl.bicep                 # NTFS permissions on the share root
├── scripts/
│   ├── Install-ADDS.ps1               # Installs the AD DS role
│   ├── Promote-DC.ps1                 # Creates the forest
│   ├── Configure-ADLab.ps1            # DNS forwarder, UPN suffix, OUs, groups, users
│   ├── Prepare-EntraConnect.ps1       # TLS 1.2, IE ESC, prerequisite checks, download shortcut
│   ├── Join-StorageAccountToAD.ps1    # Storage account AD DS join + default share permission
│   ├── Prepare-Client.ps1             # Remote Desktop Users, AD module, AzFilesHybrid
│   ├── Set-ShareAcl.ps1               # NTFS permissions with the storage account key
│   ├── Set-ShareRbac.ps1              # Group RBAC at share scope (from your workstation)
│   ├── Test-FileShareAccess.ps1       # Smoke test from CLIENT01
│   └── Remove-LabSyncedObjects.ps1    # Removes the lab objects from Entra ID before clean up
└── docs/
    ├── quick-start.md                 # This guide
    └── deployment-guide.md            # How it works, verification and troubleshooting
```
