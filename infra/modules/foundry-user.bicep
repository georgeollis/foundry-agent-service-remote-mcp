param accountName string
param operatorPrincipalId string

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource operator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, operatorPrincipalId, 'foundry-user')
  scope: account
  properties: {
    principalId: operatorPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '53ca6127-db72-4b80-b1b0-d745d6d5456d'
    )
  }
}
