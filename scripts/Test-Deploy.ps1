[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$testRoot = Join-Path $root ('.azure\script-tests\' + [guid]::NewGuid())
$mockAzure = [pscustomobject]@{
    createdDeployments = 0
    failValidation = $false
    tenant = 'test-tenant'
    portalState = 'Succeeded'
    portalSubscription = 'test-subscription'
    portalEnvironment = 'test-environment'
    portalMissingOutput = $false
    completed = [Collections.Generic.List[string]]::new()
}
$previousOperator = $env:AZURE_OPERATOR_OBJECT_ID
$previousEnvironment = $env:AZURE_ENVIRONMENT_NAME
$previousPassword = $env:VM_ADMIN_PASSWORD

function az {
    $global:LASTEXITCODE = 0
    $command = $args -join ' '
    switch -Regex ($command) {
        '^account show' { return (@{ id = 'test-subscription'; tenantId = $mockAzure.tenant } | ConvertTo-Json) }
        '^ad signed-in-user show' { return 'test-operator' }
        '^bicep build-params' {
            return (@{
                operator = $env:AZURE_OPERATOR_OBJECT_ID
                connection = $env:AZURE_MCP_CONNECTION_NAME
                password = $env:VM_ADMIN_PASSWORD
            } | ConvertTo-Json)
        }
        '^deployment sub validate' {
            if ($mockAzure.failValidation) {
                $global:LASTEXITCODE = 1
                return '{"error":{"code":"TestValidationFailure"}}'
            }
            return '{}'
        }
        '^deployment sub what-if' { return '{"changes":[]}' }
        '^deployment sub show' {
            $portalOutputs = @{
                subscriptionId = @{ value = $mockAzure.portalSubscription }
                deployedEnvironmentName = @{ value = $mockAzure.portalEnvironment }
                resourceGroupName = @{ value = 'test-resource-group' }
                vmName = @{ value = 'test-vm' }
                functionName = @{ value = 'test-function' }
                functionHostname = @{ value = 'mcp.example.invalid' }
                mcpEndpoint = @{ value = 'https://mcp.example.invalid' }
                foundryProjectEndpoint = @{ value = 'https://foundry.example.invalid' }
                foundryAccountName = @{ value = 'test-foundry-account' }
                foundryProjectName = @{ value = 'test-foundry-project' }
                foundryVnetName = @{ value = 'test-foundry-vnet' }
                functionVnetName = @{ value = 'test-function-vnet' }
                tenantId = @{ value = $mockAzure.tenant }
            }
            if ($mockAzure.portalMissingOutput) { $portalOutputs.Remove('functionName') }
            return (@{
                properties = @{
                    provisioningState = $mockAzure.portalState
                    outputs = $portalOutputs
                }
            } | ConvertTo-Json -Depth 10)
        }
        '^feature show' { return 'Registered' }
        '^provider show' { return 'Registered' }
        '^deployment sub create' {
            $mockAzure.createdDeployments++
            return '{"properties":{"provisioningState":"Succeeded","outputs":{}}}'
        }
        default { throw "Unexpected Azure command in offline test: $command" }
    }
}

function Assert-Rejected {
    param([scriptblock]$Action, [string]$ExpectedError)
    try {
        & $Action | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch $ExpectedError) { throw }
        return
    }
    throw "Expected rejection matching: $ExpectedError"
}

try {
    New-Item -ItemType Directory -Path (Join-Path $testRoot 'scripts'), (Join-Path $testRoot 'infra') -Force | Out-Null
    $deploy = Join-Path $testRoot 'scripts\Deploy.ps1'
    Copy-Item (Join-Path $PSScriptRoot 'Deploy.ps1') $deploy
    $template = Join-Path $testRoot 'infra\main.bicep'
    Set-Content $template "targetScope = 'subscription'"
    Set-Content (Join-Path $testRoot 'infra\main.bicepparam') "using './main.bicep'"
    $arguments = @{ SubscriptionId = 'test-subscription'; EnvironmentName = 'test-environment' }
    $state = Join-Path $testRoot '.azure\test-subscription\test-environment'
    $receipt = Join-Path $state 'validation.json'

    Assert-Rejected { & $deploy @arguments -Action Deploy } 'Run Deploy.ps1 -Action Validate'
    & $deploy @arguments -Action Validate | Out-Null
    $credential = Import-Clixml (Join-Path $state 'vm-admin.credential.xml')
    if ((Get-Content $receipt -Raw).Contains($credential.GetNetworkCredential().Password)) {
        throw 'Validation receipt exposes the password.'
    }
    & $deploy @arguments -Action Deploy | Out-Null
    if ($mockAzure.createdDeployments -ne 1) { throw 'Validated deployment was not executed.' }

    Assert-Rejected {
        & $deploy @arguments -Action Deploy -McpConnectionName 'another-connection'
    } 'inputs changed'
    $mockAzure.tenant = 'another-tenant'
    Assert-Rejected { & $deploy @arguments -Action Deploy } 'inputs changed'
    $mockAzure.tenant = 'test-tenant'

    Add-Content $template '// Source changed after validation.'
    Assert-Rejected { & $deploy @arguments -Action Deploy } 'inputs changed'
    & $deploy @arguments -Action Validate | Out-Null
    $mockAzure.failValidation = $true
    Assert-Rejected { & $deploy @arguments -Action Validate } 'Azure CLI failed'
    if (Test-Path $receipt) { throw 'Failed validation retained a successful receipt.' }
    Assert-Rejected { & $deploy @arguments -Action Deploy } 'Run Deploy.ps1 -Action Validate'
    if ($mockAzure.createdDeployments -ne 1) { throw 'A rejected deployment invoked provisioning.' }

    $complete = Join-Path $testRoot 'scripts\Complete-PortalDeployment.ps1'
    Copy-Item (Join-Path $PSScriptRoot 'Complete-PortalDeployment.ps1') $complete
    Set-Content (Join-Path $testRoot 'scripts\Publish-Mcp.ps1') @'
param([string]$SubscriptionId, [string]$OutputsPath)
$mockAzure.completed.Add('publish')
'@
    Set-Content (Join-Path $testRoot 'scripts\Test-Deployment.ps1') @'
param([string]$SubscriptionId, [string]$OutputsPath)
$mockAzure.completed.Add('verify')
'@
    $portalArguments = @{ SubscriptionId = 'test-subscription'; DeploymentName = 'portal-deployment' }
    & $complete @portalArguments | Out-Null
    if (($mockAzure.completed -join ',') -ne 'publish,verify') { throw 'Portal completion did not publish then verify.' }
    $imported = Get-Content (Join-Path $state 'deployment-outputs.json') -Raw | ConvertFrom-Json
    if ($imported.subscriptionId.value -ne 'test-subscription') { throw 'Portal outputs were not imported.' }

    $mockAzure.completed.Clear()
    $mockAzure.portalState = 'Running'
    Assert-Rejected { & $complete @portalArguments } 'Wait for infrastructure'
    $mockAzure.portalState = 'Succeeded'
    $mockAzure.portalSubscription = 'another-subscription'
    Assert-Rejected { & $complete @portalArguments } 'subscription does not match'
    $mockAzure.portalSubscription = 'test-subscription'
    $mockAzure.portalEnvironment = '..\outside'
    Assert-Rejected { & $complete @portalArguments } 'Environment name must'
    $mockAzure.portalEnvironment = 'test-environment'
    $mockAzure.portalMissingOutput = $true
    Assert-Rejected { & $complete @portalArguments } 'missing output functionName'
    if ($mockAzure.completed.Count -ne 0) { throw 'An invalid portal deployment invoked publishing.' }

    Write-Output 'PASS: validation gate, input drift, receipt invalidation, password exclusion, and portal completion/import/rejection checks.'
} finally {
    $env:AZURE_OPERATOR_OBJECT_ID = $previousOperator
    $env:AZURE_ENVIRONMENT_NAME = $previousEnvironment
    $env:VM_ADMIN_PASSWORD = $previousPassword
    $credential = $null
    if (Test-Path $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
