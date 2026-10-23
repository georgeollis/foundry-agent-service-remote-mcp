[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$DeploymentName
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$result = az deployment sub show --subscription $SubscriptionId --name $DeploymentName --output json
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the portal deployment. Check its subscription and deployment name.' }
$deployment = $result | ConvertFrom-Json
if ($deployment.properties.provisioningState -ne 'Succeeded') {
    throw "Wait for infrastructure deployment to succeed. Current state: $($deployment.properties.provisioningState)"
}

$outputs = $deployment.properties.outputs
foreach ($name in @('subscriptionId', 'deployedEnvironmentName', 'resourceGroupName', 'vmName',
    'functionName', 'functionHostname', 'mcpEndpoint', 'foundryProjectEndpoint',
    'foundryAccountName', 'foundryProjectName', 'foundryVnetName', 'functionVnetName', 'tenantId',
    'openApiFunctionName', 'openApiFunctionHostname', 'openApiBaseUrl', 'openApiSpecUrl')) {
    if ([string]::IsNullOrWhiteSpace($outputs.$name.value)) {
        throw "Not a complete Foundry Agent Service Remote MCP deployment: missing output $name."
    }
}
if ($outputs.subscriptionId.value -ne $SubscriptionId) { throw 'Deployment output subscription does not match.' }
$environment = $outputs.deployedEnvironmentName.value
if ($environment -notmatch '^[a-z0-9][a-z0-9-]{2,39}$') {
    throw 'Environment name must contain 3-40 lowercase letters, numbers, or hyphens.'
}

$stateDirectory = Join-Path $root ".azure\$SubscriptionId\$environment"
New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
$outputsPath = Join-Path $stateDirectory 'deployment-outputs.json'
$outputs | ConvertTo-Json -Depth 10 | Set-Content $outputsPath

& (Join-Path $PSScriptRoot 'Publish-Functions.ps1') -SubscriptionId $SubscriptionId -OutputsPath $outputsPath
& (Join-Path $PSScriptRoot 'Test-Deployment.ps1') -SubscriptionId $SubscriptionId -OutputsPath $outputsPath
Write-Output "Foundry: $($outputs.foundryProjectEndpoint.value)"
Write-Output "MCP: $($outputs.mcpEndpoint.value)"
Write-Output "OpenAPI: $($outputs.openApiSpecUrl.value)"
