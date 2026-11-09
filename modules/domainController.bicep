@description('Azure region')
param location string

@description('Domain Controller VM name')
param vmName string = 'vm-dc01'

@description('Domain Controller computer name')
param computerName string = 'DC01'

@description('VM size')
param vmSize string = 'Standard_D2s_v5'

@description('Administrator username (becomes a Domain Admin after promotion)')
param adminUsername string

@secure()
@description('Administrator password')
param adminPassword string

@description('Domain Controller subnet resource ID')
param subnetId string

@description('Domain Controller private IP')
param privateIpAddress string = '10.10.1.10'

// Active Directory Parameters

@description('FQDN of the new AD DS forest root domain')
param domainName string

@description('NetBIOS name of the new AD DS domain')
param netbiosName string

@secure()
@description('Directory Services Restore Mode (DSRM) password')
param dsrmPassword string

@description('UPN suffix for the lab users (verified Microsoft Entra domain). Empty = use the AD DS domain name.')
param upnSuffix string = ''

@secure()
@description('Password for the lab test users')
param labUserPassword string

@description('Seconds to wait after the promotion before configuring AD, so the post-promotion restart has started')
@minValue(120)
param rebootWaitSeconds int = 180

// Domain Controller Network Interface

resource dcNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location

  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'

        properties: {
          primary: true
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIpAddress

          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

// Domain Controller Virtual Machine

resource dcVM 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location

  // Used to join the storage account to AD DS (filesAdJoin.bicep)
  identity: {
    type: 'SystemAssigned'
  }

  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }

    osProfile: {
      computerName: computerName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }

    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }

      osDisk: {
        createOption: 'FromImage'

        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }

    networkProfile: {
      networkInterfaces: [
        {
          id: dcNic.id
          properties: {
            primary: true
          }
        }
      ]
    }
  }
}

// Step 1: Install the AD DS role

resource installAdds 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: dcVM
  name: 'install-adds'
  location: location

  properties: {
    source: {
      script: loadTextContent('../scripts/Install-ADDS.ps1')
    }
    asyncExecution: false
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
}

// Step 2: Promote to Domain Controller (new forest)
// The script schedules a restart 60 seconds after it finishes.

resource promoteDc 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: dcVM
  name: 'promote-dc'
  location: location
  dependsOn: [
    installAdds
  ]

  properties: {
    source: {
      script: loadTextContent('../scripts/Promote-DC.ps1')
    }
    parameters: [
      { name: 'DomainName', value: domainName }
      { name: 'NetBIOSName', value: netbiosName }
    ]
    protectedParameters: [
      { name: 'DsrmPassword', value: dsrmPassword }
    ]
    asyncExecution: false
    timeoutInSeconds: 3600
    treatFailureAsDeploymentFailure: true
  }
}

// Step 3: Wait for the post-promotion restart
// A Run Command that is running when Windows restarts gets interrupted,
// so the next one must only start after the restart has begun.
// This runs outside the VM (Azure Container Instance), with no identity.

resource waitForReboot 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'wait-for-${vmName}-reboot'
  location: location
  kind: 'AzureCLI'
  dependsOn: [
    promoteDc
  ]

  properties: {
    azCliVersion: '2.61.0'
    scriptContent: 'sleep ${rebootWaitSeconds}'
    timeout: 'PT30M'
    retentionInterval: 'PT1H'
    cleanupPreference: 'Always'
  }
}

// Step 4: Configure DNS forwarder, UPN suffix, OUs, groups and users
// The script waits up to 20 minutes for AD DS to come up after the restart.

resource configureAd 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: dcVM
  name: 'configure-ad'
  location: location
  dependsOn: [
    waitForReboot
  ]

  properties: {
    source: {
      script: loadTextContent('../scripts/Configure-ADLab.ps1')
    }
    // UpnSuffix is only passed when set, so the script falls back to the domain name
    parameters: empty(upnSuffix) ? [] : [
      { name: 'UpnSuffix', value: upnSuffix }
    ]
    protectedParameters: [
      { name: 'UserPassword', value: labUserPassword }
    ]
    asyncExecution: false
    timeoutInSeconds: 3600
    treatFailureAsDeploymentFailure: true
  }
}

// Step 5: Prepare DC01 for Microsoft Entra Connect Sync
// TLS 1.2, IE ESC off, prerequisite checks, download shortcut.
// The Entra Connect wizard itself is run manually (unattended install isn't supported).

resource prepareEntraConnect 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: dcVM
  name: 'prepare-entra-connect'
  location: location
  dependsOn: [
    configureAd
  ]

  properties: {
    source: {
      script: loadTextContent('../scripts/Prepare-EntraConnect.ps1')
    }
    asyncExecution: false
    timeoutInSeconds: 900
    treatFailureAsDeploymentFailure: true
  }
}

// Outputs

output vmId string = dcVM.id
output vmName string = dcVM.name
output privateIp string = privateIpAddress
output nicId string = dcNic.id
output domainName string = domainName
output principalId string = dcVM.identity.principalId
