param location string
param suffix string
param tags object
param vmSubnetId string
param bastionSubnetId string
param vmAdminUsername string
@secure()
param vmAdminPassword string
param vmSize string
param operatorPrincipalId string

resource bastionIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-bastion-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: 'bas-${suffix}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    scaleUnits: 2
    enableTunneling: true
    enableIpConnect: true
    ipConfigurations: [
      {
        name: 'configuration'
        properties: {
          subnet: { id: bastionSubnetId }
          publicIPAddress: { id: bastionIp.id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-workstation-${suffix}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'private'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: vmSubnetId }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: 'vm-win11-${suffix}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    licenseType: 'Windows_Client'
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'windows-11'
        sku: 'win11-24h2-pro'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    osProfile: {
      computerName: 'win11-private'
      adminUsername: vmAdminUsername
      adminPassword: vmAdminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: { deleteOption: 'Delete' }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: { enabled: true }
    }
  }
}

resource entraLogin 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: vm
  name: 'AADLoginForWindows'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

resource vmLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, operatorPrincipalId, 'vm-admin-login')
  scope: vm
  properties: {
    principalId: operatorPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '1c0163c0-47e6-4577-8991-ea5c82e286e4'
    )
  }
}

output vmName string = vm.name
output vmPrincipalId string = vm.identity.principalId
output bastionName string = bastion.name
