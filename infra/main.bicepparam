using './main.bicep'

param location = 'swedencentral'
param searchLocation = 'norwayeast'
param mcpConnectionName = readEnvironmentVariable('AZURE_MCP_CONNECTION_NAME', 'pet-insurance-mcp')
param environmentName = readEnvironmentVariable('AZURE_ENVIRONMENT_NAME', 'foundry-private-poc')
param operatorPrincipalId = readEnvironmentVariable('AZURE_OPERATOR_OBJECT_ID')
param vmAdminPassword = readEnvironmentVariable('VM_ADMIN_PASSWORD')
