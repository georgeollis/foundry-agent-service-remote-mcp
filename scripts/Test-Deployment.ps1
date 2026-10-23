[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$OutputsPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
if (-not $OutputsPath) { $OutputsPath = Join-Path $root '.azure\deployment-outputs.json' }
$OutputsPath = (Resolve-Path $OutputsPath).Path
$outputs = Get-Content $OutputsPath -Raw | ConvertFrom-Json
if ($outputs.subscriptionId.value -ne $SubscriptionId) {
    throw 'Deployment outputs do not belong to the requested subscription. Supply the correct OutputsPath.'
}
$group = $outputs.resourceGroupName.value

function Invoke-Azure {
    param([string[]]$Arguments)
    $result = & az @Arguments --subscription $SubscriptionId --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..1] -join ' ')" }
    return $result | ConvertFrom-Json
}

$resources = Invoke-Azure @('resource', 'list', '--resource-group', $group)
$endpoints = Invoke-Azure @('network', 'private-endpoint', 'list', '--resource-group', $group)
if ($endpoints.Count -ne 9) { throw "Expected nine private endpoints, found $($endpoints.Count)." }
foreach ($endpoint in $endpoints) {
    foreach ($connection in $endpoint.privateLinkServiceConnections) {
        if ($connection.privateLinkServiceConnectionState.status -ne 'Approved') {
            throw "Private endpoint is not approved: $($endpoint.name)"
        }
    }
}

foreach ($vnet in @($outputs.foundryVnetName.value, $outputs.functionVnetName.value)) {
    $peers = Invoke-Azure @('network', 'vnet', 'peering', 'list', '--resource-group', $group, '--vnet-name', $vnet)
    if ($peers.Count -ne 1 -or $peers[0].peeringState -ne 'Connected') { throw "Peering not connected: $vnet" }
}
$zones = Invoke-Azure @('network', 'private-dns', 'zone', 'list', '--resource-group', $group)
$privateDnsHosts = @()
foreach ($zone in $zones) {
    $links = Invoke-Azure @('network', 'private-dns', 'link', 'vnet', 'list', '--resource-group', $group, '--zone-name', $zone.name)
    if ($links.Count -ne 2) { throw "Expected both VNet DNS links: $($zone.name)" }
    $records = Invoke-Azure @('network', 'private-dns', 'record-set', 'a', 'list', '--resource-group', $group, '--zone-name', $zone.name)
    if (-not $records) { throw "Private DNS zone has no endpoint A records: $($zone.name)" }
    $privateDnsHosts += $records.fqdn | ForEach-Object { $_.TrimEnd('.') }
}

$appId = "/subscriptions/$SubscriptionId/resourceGroups/$group/providers/Microsoft.Web/sites/$($outputs.functionName.value)"
$appResource = Invoke-Azure @('rest', '--method', 'get', '--url', "https://management.azure.com$appId`?api-version=2024-04-01")
$app = $appResource.properties
if ($app.publicNetworkAccess -ne 'Disabled') { throw 'Function public access is not disabled.' }
if ($app.virtualNetworkSubnetId -notmatch '/egress-subnet$') { throw 'Function outbound VNet integration is missing.' }
$functionPlan = Invoke-Azure @('rest', '--method', 'get', '--url', "https://management.azure.com$($app.serverFarmId)?api-version=2024-04-01")
if ($functionPlan.sku.name -ne 'FC1') { throw 'Function is not running on Flex Consumption.' }
$nats = Invoke-Azure @('network', 'nat', 'gateway', 'list', '--resource-group', $group)
if ($nats.Count -ne 2) { throw 'Expected two NAT gateways.' }
$foundryVnet = Invoke-Azure @('network', 'vnet', 'show', '--resource-group', $group, '--name', $outputs.foundryVnetName.value)
foreach ($subnet in ($foundryVnet.subnets | Where-Object { $_.name -in @('agent-subnet', 'workstation-subnet') })) {
    if (-not $subnet.natGateway.id) { throw "NAT association missing: $($subnet.name)" }
}
$functionVnet = Invoke-Azure @('network', 'vnet', 'show', '--resource-group', $group, '--name', $outputs.functionVnetName.value)
$functionEgress = $functionVnet.subnets | Where-Object { $_.name -eq 'egress-subnet' }
if (-not $functionEgress.natGateway.id) { throw 'Function NAT association is missing.' }
$vm = Invoke-Azure @('vm', 'show', '--resource-group', $group, '--name', $outputs.vmName.value)
if ($vm.storageProfile.imageReference.offer -ne 'windows-11') { throw 'VM image is not Windows 11.' }
$deployRoles = Invoke-Azure @('role', 'assignment', 'list', '--scope', $appId,
    '--assignee-object-id', $vm.identity.principalId, '--fill-principal-name', 'false')
if ('Website Contributor' -notin $deployRoles.roleDefinitionName) { throw 'VM private-publishing role is missing.' }
foreach ($nicReference in $vm.networkProfile.networkInterfaces) {
    $nic = Invoke-Azure @('network', 'nic', 'show', '--ids', $nicReference.id)
    if ($nic.ipConfigurations.publicIPAddress) { throw 'VM has a public IP address.' }
}

$privateTypes = @(
    'Microsoft.CognitiveServices/accounts',
    'Microsoft.Search/searchServices',
    'Microsoft.DocumentDB/databaseAccounts',
    'Microsoft.ContainerRegistry/registries',
    'Microsoft.Insights/components',
    'Microsoft.OperationalInsights/workspaces'
)
foreach ($resource in ($resources | Where-Object { $_.type -in $privateTypes })) {
    $detail = Invoke-Azure @('resource', 'show', '--ids', $resource.id)
    $properties = $detail.properties
    if ($resource.type -in @('Microsoft.Insights/components', 'Microsoft.OperationalInsights/workspaces')) {
        if ($properties.publicNetworkAccessForIngestion -ne 'Disabled' -or $properties.publicNetworkAccessForQuery -ne 'Disabled') {
            throw "Monitoring public access enabled: $($resource.name)"
        }
    } elseif ($properties.publicNetworkAccess -notmatch '^disabled$') {
        throw "Public access enabled: $($resource.name)"
    }
}
$storage = Invoke-Azure @('storage', 'account', 'list', '--resource-group', $group)
$identities = Invoke-Azure @('identity', 'list', '--resource-group', $group)
$functionIdentity = $identities | Where-Object { $_.name.StartsWith('id-mcp-') }
if (-not $functionIdentity.principalId) { throw 'Function managed identity is missing.' }
foreach ($account in $storage) {
    if ($account.allowBlobPublicAccess -ne $false -or $account.allowSharedKeyAccess -ne $false) {
        throw "Storage authentication invariant failed: $($account.name)"
    }
    if ($account.publicNetworkAccess -ne 'Disabled') { throw "Storage network access mismatch: $($account.name)" }
    if ($account.name.StartsWith('stmcp')) {
        $roles = Invoke-Azure @('role', 'assignment', 'list', '--scope', $account.id,
            '--assignee-object-id', $functionIdentity.principalId, '--fill-principal-name', 'false')
        foreach ($role in @('Storage Blob Data Owner', 'Storage Queue Data Contributor')) {
            if ($role -notin $roles.roleDefinitionName) { throw "Function storage role missing: $role" }
        }
    }
}

$projectId = "/subscriptions/$SubscriptionId/resourceGroups/$group/providers/Microsoft.CognitiveServices/accounts/$($outputs.foundryAccountName.value)/projects/$($outputs.foundryProjectName.value)"
$project = Invoke-Azure @('rest', '--method', 'get', '--url', "https://management.azure.com$projectId`?api-version=2025-04-01-preview")
$projectPrincipalId = $project.identity.principalId
if (-not $projectPrincipalId) { throw 'Foundry project managed identity is missing.' }
$projectRoles = Invoke-Azure @('role', 'assignment', 'list', '--all', '--assignee-object-id', $projectPrincipalId,
    '--fill-principal-name', 'false')
foreach ($role in @('Storage Blob Data Contributor', 'Storage Blob Data Owner', 'Search Index Data Contributor', 'Search Service Contributor', 'Cosmos DB Operator', 'AcrPull')) {
    if ($role -notin $projectRoles.roleDefinitionName) { throw "Foundry project role missing: $role" }
}
$cosmosAccount = $resources | Where-Object { $_.type -eq 'Microsoft.DocumentDB/databaseAccounts' }
$cosmosRoles = Invoke-Azure @('cosmosdb', 'sql', 'role', 'assignment', 'list', '--resource-group', $group,
    '--account-name', $cosmosAccount.name)
if ($projectPrincipalId -notin $cosmosRoles.principalId) { throw 'Foundry Cosmos DB data-plane role is missing.' }

$scmHostname = ($app.enabledHostNames | Where-Object { $_ -match '\.scm\.' } | Select-Object -First 1)
if (-not $scmHostname) { throw 'SCM hostname is missing.' }
$hosts = @($outputs.functionHostname.value, $scmHostname,
    "$($outputs.foundryAccountName.value).services.ai.azure.com",
    "$($outputs.foundryAccountName.value).openai.azure.com",
    "$($outputs.foundryAccountName.value).cognitiveservices.azure.com")
$hosts += $storage | ForEach-Object { ([uri]$_.primaryEndpoints.blob).DnsSafeHost }
$hosts += $storage | Where-Object { $_.name.StartsWith('stmcp') } | ForEach-Object { ([uri]$_.primaryEndpoints.queue).DnsSafeHost }
$hosts += $resources | Where-Object { $_.type -eq 'Microsoft.Search/searchServices' } | ForEach-Object { "$($_.name).search.windows.net" }
$hosts += $resources | Where-Object { $_.type -eq 'Microsoft.DocumentDB/databaseAccounts' } | ForEach-Object { "$($_.name).documents.azure.com" }
$hosts += $resources | Where-Object { $_.type -eq 'Microsoft.ContainerRegistry/registries' } | ForEach-Object { "$($_.name).azurecr.io" }
$hosts += $privateDnsHosts
$hosts += $endpoints.customDnsConfigs.fqdn | Where-Object { $_ }
$hostJson = $hosts | Select-Object -Unique | ConvertTo-Json -Compress
$script = @'
$ErrorActionPreference = 'Stop'
Clear-DnsClientCache
$hostsToTest = '__HOSTS__' | ConvertFrom-Json
foreach ($hostname in $hostsToTest) {
    $addresses = @(Resolve-DnsName $hostname -Type A | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress)
    if ($addresses.Count -eq 0) { throw "No DNS A records: $hostname" }
    foreach ($address in $addresses) {
        if ($address -notmatch '^10\.(80|81)\.') { throw "Not a deployment private IP: $hostname = $address" }
    }
    Write-Output "PRIVATE_DNS_OK $hostname"
}
$headers = @{ Accept = 'application/json, text/event-stream' }
$endpoint = '__ENDPOINT__'
function Invoke-Mcp {
    param([string]$Method, [object]$Parameters, [int]$Id)
    $body = @{jsonrpc='2.0'; method=$Method}
    if ($Parameters) { $body.params = $Parameters }
    if ($Id) { $body.id = $Id }
    $response = Invoke-WebRequest -Uri $endpoint -Method Post -ContentType 'application/json' -Headers $headers `
        -Body ($body | ConvertTo-Json -Depth 20 -Compress) -UseBasicParsing -TimeoutSec 180
    if ($response.Headers['Mcp-Session-Id']) { $headers['Mcp-Session-Id'] = $response.Headers['Mcp-Session-Id'] }
    if (-not $response.Content) { return }
    $text = $response.Content
    if ($text -match '(?m)^data:') {
        $text = (($text -split "\r?\n" | Where-Object { $_ -match '^data:\s*' }) -replace '^data:\s*','') -join "`n"
    }
    $message = $text | ConvertFrom-Json
    if ($message.error) { throw ($message.error | ConvertTo-Json -Compress) }
    return $message
}
$initialize = Invoke-Mcp 'initialize' @{protocolVersion='2025-03-26'; capabilities=@{}; clientInfo=@{name='private-deployment-check';version='1.0'}} 1
if (-not $initialize.result.protocolVersion) { throw 'MCP initialize did not return protocolVersion.' }
$headers['MCP-Protocol-Version'] = $initialize.result.protocolVersion
Invoke-Mcp 'notifications/initialized' @{} 0 | Out-Null
$tools = Invoke-Mcp 'tools/list' @{} 2
$expected = @('check_coverage', 'request_pre_auth', 'check_claim_status', 'submit_claim_documents')
foreach ($name in $expected) {
    if ($name -notin $tools.result.tools.name) { throw "MCP tool missing: $name" }
}
$calls = @(
    @{name='check_coverage'; arguments=@{policy_number='TEST-POLICY';pet_name='Test Pet';service_type='wellness'}},
    @{name='request_pre_auth'; arguments=@{policy_number='TEST-POLICY';pet_name='Test Pet';service_type='wellness';estimated_cost=100}},
    @{name='check_claim_status'; arguments=@{claim_number='TEST-CLAIM'}},
    @{name='submit_claim_documents'; arguments=@{claim_number='TEST-CLAIM';documents='test-invoice.pdf';source='deployment-check'}}
)
$id = 3
foreach ($call in $calls) {
    $response = Invoke-Mcp 'tools/call' $call $id
    if (-not $response.result -or $response.result.isError) { throw "MCP tool call failed: $($call.name)" }
    Write-Output "MCP_TOOL_OK $($call.name)"
    $id++
}
Write-Output 'PRIVATE_DEPLOYMENT_CHECK_SUCCEEDED'
'@
$script = $script.Replace('__HOSTS__', $hostJson).Replace('__ENDPOINT__', $outputs.mcpEndpoint.value)
$temporaryScript = Join-Path ([IO.Path]::GetTempPath()) ("test-mcp-{0}.ps1" -f [guid]::NewGuid())
try {
    Set-Content $temporaryScript $script
    $result = Invoke-Azure @('vm', 'run-command', 'invoke', '--resource-group', $group, '--name', $outputs.vmName.value,
        '--command-id', 'RunPowerShellScript', '--scripts', "@$temporaryScript")
    $messages = $result.value.message -join "`n"
    Write-Output $messages
    if ($messages -notmatch 'PRIVATE_DEPLOYMENT_CHECK_SUCCEEDED') { throw 'Private data-plane verification did not succeed.' }
    $report = @{
        checkedAt = [datetime]::UtcNow.ToString('o')
        subscriptionId = $SubscriptionId
        tenantId = $outputs.tenantId.value
        environmentName = $outputs.deployedEnvironmentName.value
        managementPlane = 'Passed'
        privateDataPlane = 'Passed'
        mcpTools = 4
    }
    $report | ConvertTo-Json | Set-Content (Join-Path (Split-Path $OutputsPath) 'verification.json')
} finally {
    Remove-Item $temporaryScript -ErrorAction SilentlyContinue
}
