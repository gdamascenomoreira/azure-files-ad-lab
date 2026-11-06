@description('Azure region')
param location string

@description('Domain Controller VM name (runs the join)')
param dcVmName string

@description('Principal ID of the Domain Controller managed identity')
param dcPrincipalId string

@description('Storage account name')
param storageAccountName string

@description('OU for the storage account computer object')
param ouPath string

// Storage Account Contributor: read the account, regenerate and
// list kerb keys, and update the AD DS properties
var storageAccountContributorRoleId = '17d1049b-9a84-46fb-8f53-869881c3d3ab'

resource dcVM 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: dcVmName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName
}

// Role assignment for the DC managed identity on the storage account

resource dcStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, dcPrincipalId, storageAccountContributorRoleId)
  scope: storageAccount

  properties: {
    principalId: dcPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageAccountContributorRoleId)
  }
}

// Join the storage account to AD DS (runs on the DC)
// The script retries while the role assignment propagates.

resource joinStorage 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: dcVM
  name: 'join-storage-ad'
  location: location
  dependsOn: [
    dcStorageRole
  ]

  properties: {
    source: {
      script: loadTextContent('../scripts/Join-StorageAccountToAD.ps1')
    }
    parameters: [
      { name: 'StorageAccountId', value: storageAccount.id }
      { name: 'OuPath', value: ouPath }
      { name: 'ArmEndpoint', value: environment().resourceManager }
      { name: 'StorageSuffix', value: environment().suffixes.storage }
    ]
    asyncExecution: false
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
}
