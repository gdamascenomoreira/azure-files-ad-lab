using './main.bicep'

// General
param location = 'northeurope'

// Networking
param vnetName = 'vnet-fileslab'

// Domain Controller
param adminUsername = 'labadmin'
param dcVmSize = 'Standard_D2s_v5'

// Secure password
param adminPassword = readEnvironmentVariable('FILESLAB_VM_PASSWORD')