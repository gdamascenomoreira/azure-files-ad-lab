# Quick Start: Automated Deployment

This guide deploys the whole lab with a single Bicep deployment: an on-premises Active Directory (simulated with an Azure VM), an Azure file share behind a private endpoint, and a domain-joined client that mounts the share with Kerberos.

For a step-by-step explanation of every component, see the [Deployment Guide](deployment-guide.md).

## What gets deployed

| Component | Resource | Details |
|---|---|---|
| Network | `vnet-fileslab` | Subnets for DC, client and private endpoint. VNet DNS points to DC01 |
| Domain Controller | `vm-dc01` (DC01) | New forest `lab.contoso.com`, DNS forwarder to Azure DNS, lab OUs, groups and users |
| Storage | `stfiles<random>` | Azure file share `fileshare`, private endpoint, private DNS zone |
| AD DS join | Run Command on DC01 | Storage account computer object (AES-256), AD DS authentication enabled, default share-level permission |
| Client | `vm-client01` (CLIENT01) | Joined to the domain in `OU=LabComputers` |

Deployment order:

```
network ──┬── DC VM → install AD DS → promote → wait for reboot → configure AD ──┬── client VM + domain join
          │                                                                     └── storage AD DS join
          └── storage account + private endpoint ───────────────────────────────────┘
```

## 1. Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.53 or later, with Bicep:

  ```powershell
  az bicep install
  ```

- **Owner**, or **Contributor** plus **User Access Administrator**, on the subscription or resource group. The deployment creates a role assignment for the DC managed identity.
- Quota for **4 vCPUs** of the Dsv5 family in the target region (two `Standard_D2s_v5` VMs).
- Resource providers registered:

  ```powershell
  az login
  az account set --subscription "<subscription-id>"

  foreach ($rp in 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.ContainerInstance') {
      az provider register --namespace $rp
  }
  ```

> `Microsoft.ContainerInstance` is used by a short deployment script that waits for the DC restart after promotion. It also creates a temporary storage account with key access, which is deleted at the end. If your subscription has a policy that denies shared key access on storage accounts, that step will fail.

## 2. Get the code

```powershell
git clone https://github.com/gdamascenomoreira/azure-files-ad-lab.git
cd azure-files-ad-lab
```

## 3. Set the secrets

Secrets are read from environment variables, so they are never stored in the repository.

Use at least 12 characters with uppercase, lowercase, digits and a symbol. Avoid quotes, spaces and `$`, because the values are passed to scripts as Run Command parameters.

```powershell
$env:FILESLAB_VM_PASSWORD      = '<DC01 admin password, also the domain admin and domain join password>'
$env:FILESLAB_CLIENT_PASSWORD  = '<CLIENT01 local admin password>'
$env:FILESLAB_DSRM_PASSWORD    = '<Directory Services Restore Mode password>'
$env:FILESLAB_LABUSER_PASSWORD = '<LabUser1 and LabUser2 password>'

# Optional: verified Microsoft Entra domain, only needed with Entra Connect
# $env:FILESLAB_UPN_SUFFIX = 'contoso.com'
```

| Variable | Required | Used for |
|---|---|---|
| `FILESLAB_VM_PASSWORD` | Yes | DC01 `labadmin`, which becomes `LAB\labadmin` (Domain Admin) and joins CLIENT01 to the domain |
| `FILESLAB_CLIENT_PASSWORD` | Yes | CLIENT01 local `clientadmin` |
| `FILESLAB_DSRM_PASSWORD` | Yes | DSRM password set during promotion |
| `FILESLAB_LABUSER_PASSWORD` | Yes | `LabUser1` and `LabUser2` |
| `FILESLAB_UPN_SUFFIX` | No | UPN suffix for the lab users. Empty uses `lab.contoso.com` |

## 4. Deploy

```powershell
$rg = 'rg-fileslab'
az group create --name $rg --location northeurope

# Preview the changes
az deployment group what-if --resource-group $rg --name fileslab --parameters main.bicepparam

# Deploy
az deployment group create --resource-group $rg --name fileslab --parameters main.bicepparam
```

The deployment takes about **XX minutes** (see [Deployment times](#deployment-times)).

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
| `defaultSharePermission` | `StorageFileDataSmbShareContributor` | Share-level permission for every authenticated AD DS identity. Use `None` to rely only on group RBAC |

> The storage account name is limited to 15 characters because it becomes an AD computer name. The default is `stfiles` plus 8 random characters.

## 5. Validate

Run the smoke test on CLIENT01:

```powershell
$sa = az deployment group show -g $rg -n fileslab --query properties.outputs.storageAccountName.value -o tsv

az vm run-command invoke -g $rg -n vm-client01 --command-id RunPowerShellScript `
  --scripts "@scripts/Test-FileShareAccess.ps1" `
  --parameters "StorageAccountName=$sa" `
  --query "value[0].message" -o tsv
```

Expected result:

```
[PASS] DNS: stfilesxxxxxxxx.file.core.windows.net -> 10.10.3.x
[PASS] TCP 445: stfilesxxxxxxxx.file.core.windows.net (10.10.3.x)
[PASS] Mount (Kerberos): The command completed successfully.
[PASS] Write file: \\stfilesxxxxxxxx.file.core.windows.net\fileshare\smoke-test-CLIENT01.txt
[PASS] Kerberos ticket: cifs/stfilesxxxxxxxx.file.core.windows.net
All checks passed.
```

The test runs as SYSTEM, so it mounts the share with the `CLIENT01$` computer account and **no storage key**. A successful mount confirms DNS, the private endpoint, the domain join, the storage account AD DS join, Kerberos and the default share-level permission.

To test as a user, sign in to CLIENT01 as `LAB\LabUser1` and run:

```powershell
net use Z: \\<storage-account>.file.core.windows.net\fileshare
klist
```

## 6. Optional: Entra Connect and group RBAC

To assign share-level permissions to groups instead of (or in addition to) the default permission:

1. Install Microsoft Entra Connect Sync on DC01 (see the [Deployment Guide](deployment-guide.md)).
2. Wait for `FileShare-Users` and `FileShare-Admins` to sync to Entra ID.
3. Assign the roles at the share scope:

   ```powershell
   ./scripts/Set-ShareRbac.ps1 -ResourceGroupName $rg
   ```

| Group | Role |
|---|---|
| `FileShare-Users` | Storage File Data SMB Share Contributor |
| `FileShare-Admins` | Storage File Data SMB Share Elevated Contributor |

The script waits for the groups to sync (up to 40 minutes), only uses groups synced from AD, and can be run again safely.

> Users get the higher of the default share-level permission and their RBAC role. With the default set to Contributor, the role for `FileShare-Users` adds nothing; `FileShare-Admins` still needs Elevated Contributor to change NTFS permissions.

## 7. Clean up

```powershell
az group delete --name $rg --yes --no-wait
```

If you used Entra Connect, also delete the synced `LabUser*` and `FileShare-*` objects in Microsoft Entra ID. Each deployment creates a new forest, so old synced objects would remain as duplicates.

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
| Storage account and private endpoint | |
| Storage account AD DS join | |
| Client VM and domain join | |
| **Total** | |

To get the durations of your own deployment:

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
| `join-storage-ad` | `vm-dc01` | `Join-StorageAccountToAD.ps1` |

```powershell
az vm run-command show -g $rg --vm-name vm-dc01 -n configure-ad --instance-view --query instanceView
```

**Common issues**

| Symptom | Cause | Fix |
|---|---|---|
| `configure-ad` fails or is interrupted | Run Command started before the post-promotion restart | Increase `rebootWaitSeconds` in `modules/domainController.bicep` |
| `join-storage-ad` returns 403 for a long time | Role assignment for the DC managed identity not applied yet | The script retries for 15 minutes. Check that the deploying account can create role assignments |
| Client domain join fails | DC not ready or DNS not pointing to DC01 | Check the `configure-ad` output and the VNet DNS servers |
| DNS check returns a public IP | DC01 has no forwarder to Azure DNS | `Get-DnsServerForwarder` on DC01 should show `168.63.129.16` |
| Mount fails with access denied | No share-level permission | Check `defaultSharePermission`, or run `Set-ShareRbac.ps1` |
| Deployment fails on `wait-for-vm-dc01-reboot` | `Microsoft.ContainerInstance` not registered, or policy blocks shared key access | Register the provider, or check the policy assignments |

## Repository structure

```
azure-files-ad-lab/
├── main.bicep                         # Orchestrates all modules
├── main.bicepparam                    # Parameters (secrets from environment variables)
├── modules/
│   ├── network.bicep                  # VNet, subnets, NSG, DNS servers
│   ├── domainController.bicep         # DC01 + AD DS Run Commands
│   ├── storage.bicep                  # Storage account, file share, private endpoint, DNS zone
│   ├── filesAdJoin.bicep              # Role assignment + storage account AD DS join
│   └── clientVM.bicep                 # CLIENT01 + domain join
├── scripts/
│   ├── Install-ADDS.ps1               # Installs the AD DS role
│   ├── Promote-DC.ps1                 # Creates the forest
│   ├── Configure-ADLab.ps1            # DNS forwarder, UPN suffix, OUs, groups, users
│   ├── Join-StorageAccountToAD.ps1    # Storage account AD DS join + default share permission
│   ├── Set-ShareRbac.ps1              # Optional: group RBAC at share scope
│   └── Test-FileShareAccess.ps1       # Smoke test from CLIENT01
└── docs/
    ├── quick-start.md                 # This guide
    └── deployment-guide.md            # Detailed guide
```
