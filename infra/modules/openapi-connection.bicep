param accountName string
param projectName string
param apiBaseUrl string
param connectionName string = 'pet-insurance-openapi'

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: account
  name: projectName
}

resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: project
  name: connectionName
  properties: {
    category: 'OpenAPI'
    authType: 'None'
    target: apiBaseUrl
    isSharedToAll: false
    metadata: {
      type: 'openapi'
    }
  }
}

output projectConnectionId string = connection.id
