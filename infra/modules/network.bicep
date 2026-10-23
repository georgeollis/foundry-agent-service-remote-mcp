param location string
param suffix string
param tags object
param dnsZoneNames array

resource natIps 'Microsoft.Network/publicIPAddresses@2024-05-01' = [
  for i in range(0, 2): {
    name: 'pip-egress-${i}-${suffix}'
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
]

resource nats 'Microsoft.Network/natGateways@2024-05-01' = [
  for i in range(0, 2): {
    name: 'nat-${i}-${suffix}'
    location: location
    tags: tags
    sku: {
      name: 'Standard'
    }
    properties: {
      idleTimeoutInMinutes: 10
      publicIpAddresses: [
        { id: natIps[i].id }
      ]
    }
  }
]

resource vmNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-workstation-${suffix}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Bastion-RDP'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: '10.80.3.0/26'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Deny-Other-Inbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource foundryVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-foundry-${suffix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.80.0.0/16']
    }
    subnets: [
      {
        name: 'agent-subnet'
        properties: {
          addressPrefix: '10.80.0.0/24'
          defaultOutboundAccess: false
          natGateway: { id: nats[0].id }
          delegations: [
            {
              name: 'agent-compute'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
      {
        name: 'pe-subnet'
        properties: {
          addressPrefix: '10.80.1.0/24'
          defaultOutboundAccess: false
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'workstation-subnet'
        properties: {
          addressPrefix: '10.80.2.0/24'
          defaultOutboundAccess: false
          natGateway: { id: nats[0].id }
          networkSecurityGroup: { id: vmNsg.id }
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.80.3.0/26'
        }
      }
    ]
  }
}

resource functionVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-mcp-${suffix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.81.0.0/16']
    }
    subnets: [
      {
        name: 'pe-subnet'
        properties: {
          addressPrefix: '10.81.0.0/24'
          defaultOutboundAccess: false
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'egress-subnet'
        properties: {
          addressPrefix: '10.81.1.0/24'
          defaultOutboundAccess: false
          natGateway: { id: nats[1].id }
          delegations: [
            {
              name: 'flex-consumption'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
    ]
  }
}

resource foundryToFunction 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: foundryVnet
  name: 'to-mcp'
  properties: {
    remoteVirtualNetwork: { id: functionVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource functionToFoundry 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: functionVnet
  name: 'to-foundry'
  properties: {
    remoteVirtualNetwork: { id: foundryVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for zone in dnsZoneNames: {
    name: zone
    location: 'global'
    tags: tags
  }
]

resource foundryDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (zone, i) in dnsZoneNames: {
    parent: zones[i]
    name: 'foundry-link'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: { id: foundryVnet.id }
    }
  }
]

resource functionDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (zone, i) in dnsZoneNames: {
    parent: zones[i]
    name: 'mcp-link'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: { id: functionVnet.id }
    }
  }
]

output foundryVnetId string = foundryVnet.id
output foundryVnetName string = foundryVnet.name
output functionVnetName string = functionVnet.name
output vmSubnetId string = '${foundryVnet.id}/subnets/workstation-subnet'
output bastionSubnetId string = '${foundryVnet.id}/subnets/AzureBastionSubnet'
output functionPeSubnetId string = '${functionVnet.id}/subnets/pe-subnet'
output functionIntegrationSubnetId string = '${functionVnet.id}/subnets/egress-subnet'
