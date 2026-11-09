using './main.bicep'

// General
param location = 'northeurope'

// Networking
param vnetName = 'vnet-fileslab'

// Active Directory
param domainName = 'lab.contoso.com'
param netbiosName = 'LAB'
param upnSuffix = readEnvironmentVariable('FILESLAB_UPN_SUFFIX', '')
param dsrmPassword = readEnvironmentVariable('FILESLAB_DSRM_PASSWORD')
param labUserPassword = readEnvironmentVariable('FILESLAB_LABUSER_PASSWORD')

// Domain Controller
param adminUsername = 'labadmin'
param dcVmSize = 'Standard_D2s_v5'
param adminPassword = readEnvironmentVariable('FILESLAB_VM_PASSWORD')

// Client VM
param clientAdminUsername = 'clientadmin'
param clientVmSize = 'Standard_D2s_v5'
param clientAdminPassword = readEnvironmentVariable('FILESLAB_CLIENT_PASSWORD')

// Azure Files
param fileShareName = 'fileshare'
param fileShareQuotaGiB = 100
param defaultSharePermission = 'StorageFileDataSmbShareContributor'
