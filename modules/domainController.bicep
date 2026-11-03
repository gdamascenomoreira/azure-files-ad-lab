@description('Azure region')
param location string

@description('Domain Controller VM name')
param vmName string = 'vm-dc01'

@description('VM size')
param vmSize string = 'Standard_D2s_v5'

@description('Administrator username')
param adminUsername string

@secure()
@description('Administrator password')
param adminPassword string

@description('Domain Controller subnet resource ID')
param subnetId string

@description('Domain Controller private IP')
param privateIpAddress string = '10.10.1.10'


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

  properties: {

    hardwareProfile: {
      vmSize: vmSize
    }

    osProfile: {
      computerName: 'DC01'
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


// Outputs

output vmId string = dcVM.id
output vmName string = dcVM.name
output privateIp string = privateIpAddress
output nicId string = dcNic.id