targetScope = 'subscription'

@description('Primary region for the networks, Foundry, Function app, and workstation.')
param location string = 'swedencentral'
param environmentName string = 'foundry-private-poc'
param operatorPrincipalId string
param vmAdminUsername string = 'azureadmin'
@secure()
param vmAdminPassword string
param vmSize string = 'Standard_D2s_v5'
param modelName string = 'gpt-4.1'
param modelVersion string = '2025-04-14'
param modelCapacity int = 30
@description('Search can use a different region; its private endpoint stays in the Foundry VNet.')
param searchLocation string = 'norwayeast'
@description('Use the existing connection name when adopting a connection created in the portal.')
param mcpConnectionName string = 'pet-insurance-mcp'

var tags = {
  environment: 'development'
  workload: 'private-foundry-mcp'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

var suffix = uniqueString(subscription().id, rg.id)
var foundrySuffix = substring(uniqueString(rg.id), 0, 4)
var foundryName = 'foundry${foundrySuffix}'
var projectName = 'project${foundrySuffix}'
var foundryDnsZones = [
  'privatelink.services.ai.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.search.windows.net'
  'privatelink.blob.core.windows.net'
  'privatelink.documents.azure.com'
  'privatelink.azurecr.io'
]
var monitorDnsZones = [
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
]
var functionDnsZones = [
  'privatelink.azurewebsites.net'
  'privatelink.queue.core.windows.net'
]
var dnsZoneNames = concat(foundryDnsZones, monitorDnsZones, functionDnsZones)
var mcpServerEndpoint = 'https://${functions.outputs.functionHostname}/runtime/webhooks/mcp'

module network './modules/network.bicep' = {
  name: 'private-network'
  scope: rg
  params: {
    location: location
    suffix: suffix
    tags: tags
    dnsZoneNames: dnsZoneNames
  }
}

module access './modules/access.bicep' = {
  name: 'private-access'
  scope: rg
  params: {
    location: location
    suffix: suffix
    tags: tags
    vmSubnetId: network.outputs.vmSubnetId
    bastionSubnetId: network.outputs.bastionSubnetId
    vmAdminUsername: vmAdminUsername
    vmAdminPassword: vmAdminPassword
    vmSize: vmSize
    operatorPrincipalId: operatorPrincipalId
  }
}

module foundry './foundry/main.bicep' = {
  name: 'foundry-standard-agent'
  scope: rg
  params: {
    location: location
    aiServices: 'foundry'
    modelName: modelName
    modelVersion: modelVersion
    modelCapacity: modelCapacity
    aiSearchLocation: searchLocation
    existingVnetResourceId: network.outputs.foundryVnetId
    reuseExistingSubnets: true
    agentSubnetName: 'agent-subnet'
    peSubnetName: 'pe-subnet'
    existingDnsZones: toObject(foundryDnsZones, zone => zone, zone => rg.name)
    existingMonitorDnsZones: toObject(monitorDnsZones, zone => zone, zone => rg.name)
    disableLocalAuth: true
    developerIpCidr: ''
  }
}

module functions './modules/function.bicep' = {
  name: 'pet-insurance-mcp'
  scope: rg
  params: {
    location: location
    suffix: suffix
    tags: tags
    peSubnetId: network.outputs.functionPeSubnetId
    integrationSubnetId: network.outputs.functionIntegrationSubnetId
    deploymentVmPrincipalId: access.outputs.vmPrincipalId
    operatorPrincipalId: operatorPrincipalId
  }
}

module foundryUser './modules/foundry-user.bicep' = {
  name: 'foundry-operator'
  scope: rg
  params: {
    accountName: foundryName
    operatorPrincipalId: operatorPrincipalId
  }
  dependsOn: [
    foundry
  ]
}

module foundryMcp './modules/mcp-connection.bicep' = {
  name: 'foundry-mcp-connection'
  scope: rg
  params: {
    accountName: foundryName
    projectName: projectName
    connectionName: mcpConnectionName
    mcpEndpoint: mcpServerEndpoint
  }
  dependsOn: [
    foundry
  ]
}

output subscriptionId string = subscription().subscriptionId
output tenantId string = tenant().tenantId
output deployedEnvironmentName string = environmentName
output resourceGroupName string = rg.name
output vmName string = access.outputs.vmName
output bastionName string = access.outputs.bastionName
output functionName string = functions.outputs.functionName
output functionHostname string = functions.outputs.functionHostname
output mcpEndpoint string = mcpServerEndpoint
output foundryAccountName string = foundryName
output foundryProjectName string = projectName
output foundryProjectEndpoint string = 'https://${foundryName}.services.ai.azure.com/api/projects/${projectName}'
output foundryMcpConnectionId string = foundryMcp.outputs.projectConnectionId
output foundryVnetName string = network.outputs.foundryVnetName
output functionVnetName string = network.outputs.functionVnetName
