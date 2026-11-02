@description('Azure region')
param location string

@description('Virtual Network name')
param vnetName string

@description('Virtual Network address space')
param vnetAddressPrefix string = '10.10.0.0/16'

@description('Domain Controller subnet prefix')
param dcSubnetPrefix string = '10.10.1.0/24'

@description('Client subnet prefix')
param clientSubnetPrefix string = '10.10.2.0/24'

@description('Private Endpoint subnet prefix')
param peSubnetPrefix string = '10.10.3.0/24'

// Network Security Group
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${vnetName}-nsg'
  location: location
  properties: {
    securityRules: []
  }
}

// Virtual Network
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

// Domain Controller Subnet
resource dcSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: 'snet-dc'
  properties: {
    addressPrefix: dcSubnetPrefix
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

// Client Subnet
resource clientSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: 'snet-client'
  properties: {
    addressPrefix: clientSubnetPrefix
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

// Private Endpoint Subnet
resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: 'snet-private-endpoints'
  properties: {
    addressPrefix: peSubnetPrefix
  }
}

// Outputs
output vnetId string = vnet.id
output dcSubnetId string = dcSubnet.id
output clientSubnetId string = clientSubnet.id
output peSubnetId string = peSubnet.id