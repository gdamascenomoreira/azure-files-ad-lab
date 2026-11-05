@description('Azure deployment region')
param location string

@description('Globally unique storage account name')
param storageAccountName string

@description('Azure file share name')
param fileShareName string = 'fileshare'

@description('File share quota in GiB')
@minValue(1)
param fileShareQuotaGiB int = 100

@description('Private Endpoint subnet resource ID')
param privateEndpointSubnetId string

@description('Virtual Network resource ID')
param vnetId string

@description('Private Endpoint name')
param privateEndpointName string = 'pe-fileslab-file'

// Azure environment-specific DNS suffixes

var storageDnsSuffix = environment().suffixes.storage
var fileServiceDnsSuffix = 'file.${storageDnsSuffix}'
var privateDnsZoneName = 'privatelink.${fileServiceDnsSuffix}'

// Storage Account

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location

  sku: {
    name: 'Standard_LRS'
  }

  kind: 'StorageV2'

  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    defaultToOAuthAuthentication: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true

    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
}

// Azure Files Service

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2025-01-01' = {
  parent: storageAccount
  name: 'default'

  properties: {
    protocolSettings: {
      smb: {
        versions: 'SMB3.0;SMB3.1.1'
        authenticationMethods: 'NTLMv2;Kerberos'
        kerberosTicketEncryption: 'AES-256'
        channelEncryption: 'AES-128-GCM;AES-256-GCM'
      }
    }

    shareDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

// Azure File Share

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-01-01' = {
  parent: fileService
  name: fileShareName

  properties: {
    accessTier: 'TransactionOptimized'
    enabledProtocols: 'SMB'
    shareQuota: fileShareQuotaGiB
  }
}

// Private DNS Zone for Azure Files

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneName
  location: 'global'
}

// Private DNS Zone VNet Link

resource privateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'vnet-fileslab-link'
  location: 'global'

  properties: {
    registrationEnabled: false

    virtualNetwork: {
      id: vnetId
    }
  }
}

// Azure Files Private Endpoint

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: location

  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }

    privateLinkServiceConnections: [
      {
        name: '${privateEndpointName}-connection'

        properties: {
          privateLinkServiceId: storageAccount.id

          groupIds: [
            'file'
          ]

          privateLinkServiceConnectionState: {
            status: 'Approved'
            description: 'Approved for the Azure Files lab.'
          }
        }
      }
    ]
  }
}

// Private Endpoint DNS Zone Group

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'default'

  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'azureFilesPrivateDns'

        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

// Outputs

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output fileShareName string = fileShare.name
output privateEndpointId string = privateEndpoint.id
output privateEndpointName string = privateEndpoint.name
output privateDnsZoneId string = privateDnsZone.id
output privateDnsZoneName string = privateDnsZone.name
output fileEndpointFqdn string = '${storageAccount.name}.${fileServiceDnsSuffix}'