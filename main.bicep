targetScope = 'resourceGroup'

// General Parameters

@description('Azure deployment region')
param location string = resourceGroup().location

@description('Virtual Network name')
param vnetName string = 'vnet-fileslab'

// Domain Controller Parameters

@description('Domain Controller administrator username')
param adminUsername string = 'labadmin'

@secure()
@description('Domain Controller administrator password')
param adminPassword string

@description('Domain Controller VM size')
param dcVmSize string = 'Standard_D2s_v5'

// Client VM Parameters

@description('Client VM administrator username')
param clientAdminUsername string = 'clientadmin'

@secure()
@description('Client VM administrator password')
param clientAdminPassword string

@secure()
@description('Domain join password')
param domainJoinPassword string

@description('Client VM size')
param clientVmSize string = 'Standard_D2s_v5'

// Azure Files Parameters

@description('Globally unique storage account name')
param storageAccountName string = 'stfileslab${uniqueString(subscription().id, resourceGroup().id)}'

@description('Azure file share name')
param fileShareName string = 'fileshare'

@description('Azure file share quota in GiB')
@minValue(1)
param fileShareQuotaGiB int = 100

// Networking Module

module networking './modules/network.bicep' = {
  name: 'networkingDeployment'

  params: {
    location: location
    vnetName: vnetName
  }
}

// Domain Controller Module

module domainController './modules/domainController.bicep' = {
  name: 'domainControllerDeployment'

  params: {
    location: location
    vmName: 'vm-dc01'
    vmSize: dcVmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    subnetId: networking.outputs.dcSubnetId
    privateIpAddress: '10.10.1.10'
  }
}

// Client VM Module

module client './modules/clientVM.bicep' = {
  name: 'clientDeployment'

  params: {
    location: location
    vmName: 'vm-client01'
    computerName: 'CLIENT01'
    vmSize: clientVmSize
    adminUsername: clientAdminUsername
    adminPassword: clientAdminPassword
    subnetId: networking.outputs.clientSubnetId
    privateIpAddress: '10.10.2.10'
    domainName: 'lab.contoso.com'
    domainJoinUsername: 'LAB\\labadmin'
    domainJoinPassword: domainJoinPassword
    ouPath: 'OU=LabComputers,DC=lab,DC=contoso,DC=com'
  }
}

// Azure Files Module

module storage './modules/storage.bicep' = {
  name: 'storageDeployment'

  params: {
    location: location
    storageAccountName: storageAccountName
    fileShareName: fileShareName
    fileShareQuotaGiB: fileShareQuotaGiB
    privateEndpointSubnetId: networking.outputs.peSubnetId
    vnetId: networking.outputs.vnetId
    privateEndpointName: 'pe-fileslab-file'
  }
}

// Networking Outputs

output vnetId string = networking.outputs.vnetId
output dcSubnetId string = networking.outputs.dcSubnetId
output clientSubnetId string = networking.outputs.clientSubnetId
output peSubnetId string = networking.outputs.peSubnetId

// Domain Controller Outputs

output dcVmId string = domainController.outputs.vmId
output dcVmName string = domainController.outputs.vmName
output dcPrivateIp string = domainController.outputs.privateIp

// Client VM Outputs

output clientVmId string = client.outputs.vmId
output clientVmName string = client.outputs.vmName
output clientPrivateIp string = client.outputs.privateIp

// Azure Files Outputs

output storageAccountId string = storage.outputs.storageAccountId
output storageAccountName string = storage.outputs.storageAccountName
output fileShareName string = storage.outputs.fileShareName
output fileEndpointFqdn string = storage.outputs.fileEndpointFqdn
output privateEndpointId string = storage.outputs.privateEndpointId
output privateEndpointName string = storage.outputs.privateEndpointName
output privateDnsZoneId string = storage.outputs.privateDnsZoneId
output privateDnsZoneName string = storage.outputs.privateDnsZoneName