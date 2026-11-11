@description('Azure region')
param location string

@description('Client VM name (runs the ACL configuration)')
param clientVmName string

@description('Storage account name')
param storageAccountName string

@description('File share name')
param fileShareName string

@description('NetBIOS name of the AD DS domain')
param netbiosName string

@description('Group that gets Modify on the share root')
param usersGroup string = 'FileShare-Users'

@description('Group that gets Full Control on the share root')
param adminsGroup string = 'FileShare-Admins'

resource clientVM 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: clientVmName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName
}

// Windows ACLs on the share root, set from CLIENT01 with the storage
// account key (administrative connection, removed at the end).
// The key is passed as a protected parameter and never stored on the VM.

resource setShareAcl 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: clientVM
  name: 'set-share-acl'
  location: location

  properties: {
    source: {
      script: loadTextContent('../scripts/Set-ShareAcl.ps1')
    }
    parameters: [
      { name: 'StorageAccountName', value: storageAccountName }
      { name: 'ShareName', value: fileShareName }
      { name: 'UsersGroup', value: '${netbiosName}\\${usersGroup}' }
      { name: 'AdminsGroup', value: '${netbiosName}\\${adminsGroup}' }
      { name: 'StorageSuffix', value: environment().suffixes.storage }
    ]
    protectedParameters: [
      { name: 'StorageKey', value: storageAccount.listKeys().keys[0].value }
    ]
    asyncExecution: false
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
}
