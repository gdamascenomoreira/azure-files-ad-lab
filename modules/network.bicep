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

@description('DNS server for the VNet (Domain Controller IP)')
param dnsServerIp string = '10.10.1.10'

// Network Security Group

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${vnetName}-nsg'
  location: location
  properties: {
    securityRules: []
  }
}

// Virtual Network
// Subnets are declared inline, not as separate child resources:
//  - separate subnet resources are written in parallel on the same VNet,
//    which fails with AnotherOperationInProgress
//  - on a redeploy, a VNet without its subnets in the body would try
//    to remove subnets that are in use

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }

    dhcpOptions: {
      dnsServers: [
        dnsServerIp
      ]
    }

    subnets: [
      {
        name: 'snet-dc'
        properties: {
          addressPrefix: dcSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
      {
        name: 'snet-client'
        properties: {
          addressPrefix: clientSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: peSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }

  // References to the inline subnets (used for the outputs)

  resource dcSubnet 'subnets' existing = {
    name: 'snet-dc'
  }

  resource clientSubnet 'subnets' existing = {
    name: 'snet-client'
  }

  resource peSubnet 'subnets' existing = {
    name: 'snet-private-endpoints'
  }
}

// Outputs

output vnetId string = vnet.id
output dcSubnetId string = vnet::dcSubnet.id
output clientSubnetId string = vnet::clientSubnet.id
output peSubnetId string = vnet::peSubnet.id
