targetScope = 'resourceGroup'

// General Parameters

@description('Azure deployment region')
param location string = resourceGroup().location

@description('Virtual Network name')
param vnetName string = 'vnet-fileslab'

// Active Directory Parameters

@description('FQDN of the AD DS forest root domain')
param domainName string = 'lab.contoso.com'

@description('NetBIOS name of the AD DS domain')
@maxLength(15)
param netbiosName string = 'LAB'

@description('UPN suffix for the lab users (verified Microsoft Entra domain). Empty = use the AD DS domain name.')
param upnSuffix string = ''

@secure()
@description('Directory Services Restore Mode (DSRM) password')
param dsrmPassword string

@secure()
@description('Password for the lab test users (LabUser1, LabUser2)')
param labUserPassword string

// Domain Controller Parameters

@description('Domain Controller administrator username (becomes a Domain Admin)')
param adminUsername string = 'labadmin'

@secure()
@description('Domain Controller administrator password (also used for the domain join)')
param adminPassword string

@description('Domain Controller VM size')
param dcVmSize string = 'Standard_D2s_v5'

// Client VM Parameters

@description('Client VM administrator username')
param clientAdminUsername string = 'clientadmin'

@secure()
@description('Client VM administrator password')
param clientAdminPassword string

@description('Client VM size')
param clientVmSize string = 'Standard_D2s_v5'

// Azure Files Parameters

@description('Globally unique storage account name (max 15 characters: it becomes an AD computer name)')
@minLength(3)
@maxLength(15)
param storageAccountName string = 'stfiles${take(uniqueString(subscription().id, resourceGroup().id), 8)}'

@description('Azure file share name')
param fileShareName string = 'fileshare'

@description('Azure file share quota in GiB')
@minValue(1)
param fileShareQuotaGiB int = 100

// Derived Active Directory values
// lab.contoso.com -> DC=lab,DC=contoso,DC=com

var domainDN = join(map(split(domainName, '.'), part => 'DC=${part}'), ',')
var computersOuPath = 'OU=LabComputers,${domainDN}'
var dcPrivateIp = '10.10.1.10'

// Networking Module

module networking './modules/network.bicep' = {
  name: 'networkingDeployment'

  params: {
    location: location
    vnetName: vnetName
  }
}

// Domain Controller Module
// Deploys the VM, installs AD DS, promotes it and configures the lab objects.

module domainController './modules/domainController.bicep' = {
  name: 'domainControllerDeployment'

  params: {
    location: location
    vmName: 'vm-dc01'
    vmSize: dcVmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    subnetId: networking.outputs.dcSubnetId
    privateIpAddress: dcPrivateIp
    domainName: domainName
    netbiosName: netbiosName
    dsrmPassword: dsrmPassword
    upnSuffix: upnSuffix
    labUserPassword: labUserPassword
  }
}

// Client VM Module
// Waits for the whole Domain Controller module, so the domain
// and the LabComputers OU exist before the domain join runs.

module client './modules/clientVM.bicep' = {
  name: 'clientDeployment'
  dependsOn: [
    domainController
  ]

  params: {
    location: location
    vmName: 'vm-client01'
    computerName: 'CLIENT01'
    vmSize: clientVmSize
    adminUsername: clientAdminUsername
    adminPassword: clientAdminPassword
    subnetId: networking.outputs.clientSubnetId
    privateIpAddress: '10.10.2.10'
    domainName: domainName
    domainJoinUsername: '${netbiosName}\\${adminUsername}'
    domainJoinPassword: adminPassword
    ouPath: computersOuPath
  }
}

// Azure Files Module
// Independent from AD, so it deploys in parallel with the Domain Controller.

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

// Azure Files AD DS Join Module
// Runs after the DC is configured (LabComputers OU exists) and the storage account exists.

module filesAdJoin './modules/filesAdJoin.bicep' = {
  name: 'filesAdJoinDeployment'

  params: {
    location: location
    dcVmName: domainController.outputs.vmName
    dcPrincipalId: domainController.outputs.principalId
    storageAccountName: storage.outputs.storageAccountName
    ouPath: computersOuPath
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
output domainName string = domainController.outputs.domainName
output computersOuPath string = computersOuPath

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
