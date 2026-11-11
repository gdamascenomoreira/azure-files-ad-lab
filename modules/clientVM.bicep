@description('Azure deployment region')
param location string

@description('Client VM name')
param vmName string = 'vm-client01'

@description('Client computer name')
param computerName string = 'CLIENT01'

@description('VM size')
param vmSize string = 'Standard_D2s_v5'

@description('Administrator username')
param adminUsername string

@secure()
@description('Administrator password')
param adminPassword string

@description('Client subnet resource ID')
param subnetId string

@description('Client private IP address')
param privateIpAddress string = '10.10.2.10'

@description('Active Directory domain')
param domainName string = 'lab.contoso.com'

@description('Domain join username')
param domainJoinUsername string = 'LAB\\labadmin'

@secure()
@description('Domain join password')
param domainJoinPassword string

@description('Target Active Directory OU')
param ouPath string = 'OU=LabComputers,DC=lab,DC=contoso,DC=com'

@description('Domain groups (names without domain) added to the local Remote Desktop Users group')
param remoteDesktopGroups array = [
  'FileShare-Users'
  'FileShare-Admins'
]

// LAB\labadmin -> LAB
var netbiosName = split(domainJoinUsername, '\\')[0]


resource clientNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
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


resource clientVM 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location

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
          id: clientNic.id
          properties: {
            primary: true
          }
        }
      ]
    }
  }
}

resource domainJoinExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: clientVM
  name: 'joindomain'
  location: location

  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true

    settings: {
      Name: domainName
      User: domainJoinUsername
      OUPath: ouPath
      Restart: 'true'
      Options: 3
    }

    protectedSettings: {
      Password: domainJoinPassword
    }
  }
}

// Prepare CLIENT01: Remote Desktop Users for the lab groups,
// AD PowerShell module and AzFilesHybrid (Debug-AzStorageAccountAuth)

resource prepareClient 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: clientVM
  name: 'prepare-client'
  location: location
  dependsOn: [
    domainJoinExtension
  ]

  properties: {
    source: {
      script: loadTextContent('../scripts/Prepare-Client.ps1')
    }
    parameters: [
      {
        name: 'RemoteDesktopGroups'
        value: join(map(remoteDesktopGroups, group => '${netbiosName}\\${group}'), ',')
      }
    ]
    asyncExecution: false
    timeoutInSeconds: 3600
    treatFailureAsDeploymentFailure: true
  }
}

// Outputs

output vmId string = clientVM.id
output vmName string = clientVM.name
output privateIp string = privateIpAddress
output nicId string = clientNic.id
