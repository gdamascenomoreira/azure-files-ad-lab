# Azure Files + Active Directory Lab

Infrastructure as Code (IaC) lab for deploying and testing Azure Files integrated with on-premises Active Directory Domain Services (AD DS) and Microsoft Entra Connect Sync.

## Objective

Build a reusable Azure environment to reproduce and troubleshoot Azure Files authentication, identity synchronization, networking, and permission scenarios.

## Architecture

The environment will include:

- Azure Virtual Network
- Windows Server Domain Controller (AD DS + DNS)
- Microsoft Entra Connect Sync server
- Domain-joined Windows client
- Azure Storage Account
- Azure File Share
- Private Endpoint and Private DNS
- Azure Files AD DS authentication
- Azure RBAC and NTFS permissions

The Domain Controller will run in an Azure VM to simulate an on-premises Active Directory environment.

## Technologies

- Azure Bicep
- Azure CLI
- PowerShell
- Active Directory Domain Services
- Microsoft Entra Connect Sync
- Azure Files
- Azure Private Link

## Deployment

Deployment instructions will be documented in:

[Deployment Guide](docs/deployment-guide.md)

## Project Status

Work in progress.

## Disclaimer

This project is intended for learning and testing purposes only.

It is not a production-ready deployment.