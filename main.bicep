targetScope = 'resourceGroup'

@description('Azure deployment region')
param location string = resourceGroup().location

@description('Virtual Network name')
param vnetName string = 'vnet-fileslab'

// Deploy Networking Module
module networking './modules/network.bicep' = {
  name: 'networkingDeployment'
  params: {
    location: location
    vnetName: vnetName
  }
}

// Outputs
output vnetId string = networking.outputs.vnetId
output dcSubnetId string = networking.outputs.dcSubnetId
output clientSubnetId string = networking.outputs.clientSubnetId
output peSubnetId string = networking.outputs.peSubnetId