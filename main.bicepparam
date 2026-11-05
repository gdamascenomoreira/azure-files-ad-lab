using './main.bicep'

// General
param location = 'northeurope'

// Networking
param vnetName = 'vnet-fileslab'

// Domain Controller
param adminUsername = 'labadmin'
param dcVmSize = 'Standard_D2s_v5'
param adminPassword = readEnvironmentVariable('FILESLAB_VM_PASSWORD')

// Client VM
param clientAdminUsername = 'clientadmin'
param clientVmSize = 'Standard_D2s_v5'
param clientAdminPassword = readEnvironmentVariable('FILESLAB_CLIENT_PASSWORD')
param domainJoinPassword = readEnvironmentVariable('FILESLAB_DOMAINJOIN_PASSWORD')

// Azure Files
param fileShareName = 'fileshare'
param fileShareQuotaGiB = 100