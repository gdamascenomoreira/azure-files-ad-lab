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

// Networking Outputs

output vnetId string = networking.outputs.vnetId
output dcSubnetId string = networking.outputs.dcSubnetId
output clientSubnetId string = networking.outputs.clientSubnetId
output peSubnetId string = networking.outputs.peSubnetId

// Domain Controller Outputs

output dcVmId string = domainController.outputs.vmId
output dcVmName string = domainController.outputs.vmName
output dcPrivateIp string = domainController.outputs.privateIp