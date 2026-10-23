[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$OutputsPath,
    [ValidateSet('Mcp', 'OpenApi', 'All')][string]$Service = 'All'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
if (-not $OutputsPath) { $OutputsPath = Join-Path $root '.azure\deployment-outputs.json' }
$outputs = Get-Content $OutputsPath -Raw | ConvertFrom-Json
if ($outputs.subscriptionId.value -ne $SubscriptionId) {
    throw 'Deployment outputs do not belong to the requested subscription. Supply the correct OutputsPath.'
}
$targets = @(
    @{ Name = 'Mcp'; FunctionName = $outputs.functionName.value; Directory = 'pet-insurance' }
    @{ Name = 'OpenApi'; FunctionName = $outputs.openApiFunctionName.value; Directory = 'pet-insurance-api' }
) | Where-Object { $Service -eq 'All' -or $_.Name -eq $Service }
foreach ($target in $targets) {
    if (-not $target.FunctionName) { throw "Missing $($target.Name) Function output. Deploy the updated infrastructure first." }
}
if ('OpenApi' -in $targets.Name -and -not $outputs.openApiBaseUrl.value) {
    throw 'OpenAPI base URL is missing from deployment outputs.'
}
$powerState = az vm get-instance-view --subscription $SubscriptionId --resource-group $outputs.resourceGroupName.value `
    --name $outputs.vmName.value --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Cannot read deployment VM power state.' }
if ($powerState -ne 'PowerState/running') {
    Write-Output "Starting private deployment VM (current state: $powerState)."
    az vm start --subscription $SubscriptionId --resource-group $outputs.resourceGroupName.value --name $outputs.vmName.value --output none
    if ($LASTEXITCODE -ne 0) { throw 'Cannot start private deployment VM.' }
}
foreach ($target in $targets) {
    $zip = Join-Path ([IO.Path]::GetTempPath()) ("function-{0}.zip" -f [guid]::NewGuid())
    $remoteScript = Join-Path ([IO.Path]::GetTempPath()) ("publish-function-{0}.ps1" -f [guid]::NewGuid())
    try {
        Compress-Archive -Path (Join-Path $root "src\$($target.Directory)\*") -DestinationPath $zip
        $payload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))
        $script = @'
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$az = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
if (-not (Test-Path $az)) {
    $msi = Join-Path $env:TEMP 'azure-cli.msi'
    Invoke-WebRequest 'https://aka.ms/installazurecliwindowsx64' -OutFile $msi -UseBasicParsing
    $install = Start-Process msiexec.exe -ArgumentList @('/i', $msi, '/quiet', '/norestart') -Wait -PassThru
    if ($install.ExitCode -notin @(0, 3010)) { throw "Azure CLI installation failed: $($install.ExitCode)" }
    Remove-Item $msi
}
$package = Join-Path $env:TEMP '__PACKAGE_NAME__'
[IO.File]::WriteAllBytes($package, [Convert]::FromBase64String('__PACKAGE__'))
try {
    & $az login --identity --allow-no-subscriptions --output none
    if ($LASTEXITCODE -ne 0) { throw 'Managed identity login failed.' }
    & $az functionapp deployment source config-zip --subscription '__SUBSCRIPTION__' --resource-group '__GROUP__' --name '__APP__' --src $package --build-remote true --timeout 1200 --output none
    if ($LASTEXITCODE -ne 0) { throw 'Private Function deployment failed.' }
    Write-Output 'PRIVATE_FUNCTION_PUBLISH_SUCCEEDED'
} finally {
    Remove-Item $package -ErrorAction SilentlyContinue
}
'@
        $script = $script.Replace('__PACKAGE__', $payload).Replace('__SUBSCRIPTION__', $SubscriptionId).
            Replace('__GROUP__', $outputs.resourceGroupName.value).Replace('__APP__', $target.FunctionName).
            Replace('__PACKAGE_NAME__', (Split-Path $zip -Leaf))
        Set-Content $remoteScript $script
        $result = az vm run-command invoke --subscription $SubscriptionId --resource-group $outputs.resourceGroupName.value `
            --name $outputs.vmName.value --command-id RunPowerShellScript --scripts "@$remoteScript" --output json
        if ($LASTEXITCODE -ne 0) { throw 'VM deployment command failed.' }
        $messages = (($result | ConvertFrom-Json).value.message -join "`n")
        Write-Output $messages
        if ($messages -notmatch 'PRIVATE_FUNCTION_PUBLISH_SUCCEEDED') { throw "Private $($target.Name) publish did not report success." }
    } finally {
        Remove-Item $zip, $remoteScript -ErrorAction SilentlyContinue
    }
}
if ('OpenApi' -in $targets.Name) {
    $specification = Get-Content (Join-Path $root 'src\pet-insurance-api\openapi.json') -Raw | ConvertFrom-Json
    $specification.servers = @(@{ url = $outputs.openApiBaseUrl.value })
    $specPath = Join-Path (Split-Path (Resolve-Path $OutputsPath).Path) 'openapi.json'
    $specification | ConvertTo-Json -Depth 30 | Set-Content $specPath
    Write-Output "Foundry OpenAPI import specification: $specPath"
}
