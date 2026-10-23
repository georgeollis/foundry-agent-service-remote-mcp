param accountName string
param projectName string
param connectionName string
param mcpEndpoint string

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: account
  name: projectName
}

var connectionProperties = {
  category: 'RemoteTool'
  authType: 'None'
  target: mcpEndpoint
  isSharedToAll: false
  sharedUserList: []
  peRequirement: 'NotRequired'
  peStatus: 'NotApplicable'
  useWorkspaceManagedIdentity: false
  metadata: {
    type: 'custom_MCP'
  }
}

resource accountConnection 'Microsoft.CognitiveServices/accounts/connections@2025-10-01-preview' = {
  parent: account
  name: connectionName
  properties: connectionProperties
}

resource projectConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-10-01-preview' = {
  parent: project
  name: connectionName
  properties: connectionProperties
}

output projectConnectionId string = projectConnection.id
