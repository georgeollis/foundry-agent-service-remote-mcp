[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [ValidateSet('Validate', 'Deploy')][string]$Action = 'Validate',
    [string]$DeploymentName = 'private-foundry-mcp',
    [ValidatePattern('^[a-z0-9][a-z0-9-]{2,39}$')][string]$EnvironmentName = 'foundry-private-poc',
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{2,32}$')][string]$McpConnectionName = 'pet-insurance-mcp'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$stateDirectory = Join-Path $root ".azure\$SubscriptionId\$EnvironmentName"
New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
$credentialPath = Join-Path $stateDirectory 'vm-admin.credential.xml'
$validationPath = Join-Path $stateDirectory 'validation.json'

function Invoke-Azure {
    param([string[]]$Arguments)
    $result = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..1] -join ' ')" }
    return $result
}

$account = Invoke-Azure @('account', 'show', '--subscription', $SubscriptionId, '--output', 'json') | ConvertFrom-Json
if ($account.id -ne $SubscriptionId) { throw 'Azure subscription mismatch.' }
$defaultAccount = Invoke-Azure @('account', 'show', '--output', 'json') | ConvertFrom-Json
if ($defaultAccount.tenantId -ne $account.tenantId) {
    throw 'Select the target subscription with az account set before resolving its tenant identity.'
}
$env:AZURE_OPERATOR_OBJECT_ID = Invoke-Azure @('ad', 'signed-in-user', 'show', '--query', 'id', '--output', 'tsv')
$env:AZURE_ENVIRONMENT_NAME = $EnvironmentName
$previousConnectionName = $env:AZURE_MCP_CONNECTION_NAME
$env:AZURE_MCP_CONNECTION_NAME = $McpConnectionName

if (Test-Path $credentialPath) {
    $credential = Import-Clixml $credentialPath
} else {
    $password = 'Aa1!' + [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(30))
    $credential = [pscredential]::new('azureadmin', (ConvertTo-SecureString $password -AsPlainText -Force))
    $credential | Export-Clixml $credentialPath
    $password = $null
}

try {
    $env:VM_ADMIN_PASSWORD = $credential.GetNetworkCredential().Password
    $template = Join-Path $root 'infra\main.bicep'
    $parameters = Join-Path $root 'infra\main.bicepparam'
    $compiledParameters = Invoke-Azure @('bicep', 'build-params', '--file', $parameters, '--stdout', '--only-show-errors')
    $sourceHashes = Get-ChildItem (Join-Path $root 'infra') -Recurse -File |
        Where-Object { $_.Extension -in @('.bicep', '.bicepparam') } |
        Sort-Object FullName |
        ForEach-Object { '{0}:{1}' -f [IO.Path]::GetRelativePath($root, $_.FullName), (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
    $fingerprintInput = ($sourceHashes -join "`n") + "`n" + ($compiledParameters -join "`n")
    $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fingerprintInput)))
    $compiledParameters = $null
    $fingerprintInput = $null
    $common = @('--subscription', $SubscriptionId, '--location', 'swedencentral', '--name', $DeploymentName,
        '--template-file', $template, '--parameters', $parameters, '--output', 'json')
    if ($Action -eq 'Validate') {
        if (Test-Path $validationPath) { Remove-Item $validationPath }
        $validation = Invoke-Azure (@('deployment', 'sub', 'validate') + $common) | ConvertFrom-Json
        if ($validation.error) { throw ($validation.error | ConvertTo-Json -Depth 10) }
        $whatIf = Invoke-Azure (@('deployment', 'sub', 'what-if') + $common + @('--no-pretty-print', '--result-format', 'ResourceIdOnly'))
        $whatIf | Set-Content (Join-Path $stateDirectory 'what-if.json')
        @{
            validatedAt = [datetime]::UtcNow.ToString('o')
            subscriptionId = $SubscriptionId
            tenantId = $account.tenantId
            environmentName = $EnvironmentName
            deploymentName = $DeploymentName
            mcpConnectionName = $McpConnectionName
            fingerprint = $fingerprint
        } | ConvertTo-Json | Set-Content $validationPath
        Write-Output 'Bicep compilation, ARM validation, and what-if succeeded.'
    } else {
        if (-not (Test-Path $validationPath)) {
            throw 'Run Deploy.ps1 -Action Validate with the same arguments before deployment.'
        }
        $validation = Get-Content $validationPath -Raw | ConvertFrom-Json
        if ($validation.subscriptionId -ne $SubscriptionId -or $validation.tenantId -ne $account.tenantId -or
            $validation.environmentName -ne $EnvironmentName -or $validation.deploymentName -ne $DeploymentName -or
            $validation.fingerprint -ne $fingerprint) {
            throw 'Deployment inputs changed since validation. Run Deploy.ps1 -Action Validate again.'
        }
        $featureState = Invoke-Azure @('feature', 'show', '--subscription', $SubscriptionId, '--namespace',
            'Microsoft.Network', '--name', 'AllowBringYourOwnPublicIpAddress', '--query', 'properties.state', '--output', 'tsv')
        if ($featureState -ne 'Registered') {
            Invoke-Azure @('feature', 'register', '--subscription', $SubscriptionId, '--namespace',
                'Microsoft.Network', '--name', 'AllowBringYourOwnPublicIpAddress', '--output', 'none') | Out-Null
            $featureState = Invoke-Azure @('feature', 'show', '--subscription', $SubscriptionId, '--namespace',
                'Microsoft.Network', '--name', 'AllowBringYourOwnPublicIpAddress', '--query', 'properties.state', '--output', 'tsv')
            if ($featureState -ne 'Registered') { throw 'Azure network feature registration is pending; wait for approval before retrying.' }
            Invoke-Azure @('provider', 'register', '--subscription', $SubscriptionId, '--namespace',
                'Microsoft.Network', '--wait', '--output', 'none') | Out-Null
        }
        $alertsState = Invoke-Azure @('provider', 'show', '--subscription', $SubscriptionId, '--namespace',
            'Microsoft.AlertsManagement', '--query', 'registrationState', '--output', 'tsv')
        if ($alertsState -ne 'Registered') {
            Invoke-Azure @('provider', 'register', '--subscription', $SubscriptionId, '--namespace',
                'Microsoft.AlertsManagement', '--wait', '--output', 'none') | Out-Null
        }
        $result = Invoke-Azure (@('deployment', 'sub', 'create') + $common) | ConvertFrom-Json
        if ($result.properties.provisioningState -ne 'Succeeded') { throw 'Infrastructure deployment did not succeed.' }
        $result.properties.outputs | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $stateDirectory 'deployment-outputs.json')
        Write-Output "Infrastructure deployed. Encrypted local VM credential: $credentialPath"
    }
} finally {
    Remove-Item Env:\VM_ADMIN_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:\AZURE_ENVIRONMENT_NAME -ErrorAction SilentlyContinue
    $env:AZURE_MCP_CONNECTION_NAME = $previousConnectionName
    $credential = $null
}
