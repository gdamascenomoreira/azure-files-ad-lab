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

### Phase 2 - Active Directory
Deploy the Domain Controller and configure AD DS.

### Phase 3 - Microsoft Entra Connect
Deploy the synchronization server and configure
identity synchronization.

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