# Azure Files + Active Directory Lab

Infrastructure as Code lab to reproduce and troubleshoot Azure Files with on-premises Active Directory Domain Services (AD DS) authentication, Microsoft Entra Connect Sync and Azure RBAC, the way customers run it.

## What you get

- A Domain Controller (AD DS + DNS) in an Azure VM, simulating on-premises AD, with Microsoft Entra Connect Sync
- An Azure file share behind a private endpoint, joined to AD DS
- Share-level permissions through Azure RBAC on synced groups, and NTFS permissions on the share
- A domain-joined Windows client with the troubleshooting tools (AzFilesHybrid) installed
- A smoke test that validates the whole chain: DNS, private endpoint, Kerberos, sync and RBAC

Everything is deployed with one Bicep deployment, except the Entra Connect Sync wizard.

```
DC01 (AD DS, DNS, Entra Connect) ──sync──► Microsoft Entra ID
   ▲ Kerberos                                       │ RBAC
CLIENT01 ──SMB 445──► private endpoint ──► Azure file share
```

## Getting started

- [Quick Start: automated deployment](docs/quick-start.md)
- [How It Works: architecture, verification and troubleshooting](docs/deployment-guide.md)

## Technologies

- Azure Bicep, Azure CLI, PowerShell
- Active Directory Domain Services
- Microsoft Entra Connect Sync
- Azure Files, Azure Private Link, Azure RBAC

## Disclaimer

This project is intended for learning and testing purposes only. It is not a production-ready deployment. Use a test Microsoft Entra tenant, never a production or corporate one.
