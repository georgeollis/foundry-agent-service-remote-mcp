param location string
param suffix string
param tags object
param peSubnetId string
param integrationSubnetId string
param deploymentVmPrincipalId string
param operatorPrincipalId string
param workload string = 'mcp'
param functionAppName string = 'func-pet-${suffix}'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${workload}-${suffix}'
  location: location
  tags: tags
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${workload}${suffix}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'deployment'
  properties: { publicAccess: 'None' }
}

var storageEndpointGroups = ['blob', 'queue']

resource storageEndpoints 'Microsoft.Network/privateEndpoints@2024-05-01' = [
  for group in storageEndpointGroups: {
    name: 'pe-${workload}-${group}-${suffix}'
    location: location
    tags: tags
    properties: {
      subnet: { id: peSubnetId }
      privateLinkServiceConnections: [
        {
          name: group
          properties: {
            privateLinkServiceId: storage.id
            groupIds: [group]
          }
        }
      ]
    }
  }
]

resource storageZones 'Microsoft.Network/privateDnsZones@2024-06-01' existing = [
  for group in storageEndpointGroups: {
    name: 'privatelink.${group}.core.windows.net'
  }
]

resource storageDnsGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [
  for (group, i) in storageEndpointGroups: {
    parent: storageEndpoints[i]
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: group
          properties: { privateDnsZoneId: storageZones[i].id }
        }
      ]
    }
  }
]

var storageRoles = [
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
]
resource storageRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for role in storageRoles: {
    name: guid(storage.id, identity.id, role)
    scope: storage
    properties: {
      principalId: identity.properties.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
    }
  }
]

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'plan-${workload}-${suffix}'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: { reserved: true }
}

resource app 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: integrationSubnetId
    functionAppConfig: {
      runtime: {
        name: 'python'
        version: '3.12'
      }
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainer.name}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: identity.id
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 40
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId', value: identity.properties.clientId }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: storage.properties.primaryEndpoints.blob }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: storage.properties.primaryEndpoints.queue }
      ]
    }
  }
  dependsOn: [
    storageRbac
    storageDnsGroups
  ]
}

resource deploymentRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(app.id, deploymentVmPrincipalId, 'private-publish')
  scope: app
  properties: {
    principalId: deploymentVmPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'de139f84-1756-47ae-9be6-808fbbe84772'
    )
  }
}

resource operatorStorageRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, operatorPrincipalId, 'storage-inspect')
  scope: storage
  properties: {
    principalId: operatorPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
    )
  }
}

resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${workload}-${suffix}'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: workload
        properties: {
          privateLinkServiceId: app.id
          groupIds: ['sites']
        }
      }
    ]
  }
}

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.azurewebsites.net'
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sites'
        properties: { privateDnsZoneId: zone.id }
      }
    ]
  }
}

output functionName string = app.name
output functionHostname string = app.properties.defaultHostName
