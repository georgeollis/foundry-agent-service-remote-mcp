[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$OutputsPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
if (-not $OutputsPath) { $OutputsPath = Join-Path $root '.azure\deployment-outputs.json' }
$outputs = Get-Content $OutputsPath -Raw | ConvertFrom-Json
if ($outputs.subscriptionId.value -ne $SubscriptionId) {
    throw 'Deployment outputs do not belong to the requested subscription. Supply the correct OutputsPath.'
}
$powerState = az vm get-instance-view --subscription $SubscriptionId --resource-group $outputs.resourceGroupName.value `
    --name $outputs.vmName.value --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Cannot read deployment VM power state.' }
if ($powerState -ne 'PowerState/running') {
    Write-Output "Starting private deployment VM (current state: $powerState)."
    az vm start --subscription $SubscriptionId --resource-group $outputs.resourceGroupName.value --name $outputs.vmName.value --output none
    if ($LASTEXITCODE -ne 0) { throw 'Cannot start private deployment VM.' }
}
$zip = Join-Path ([IO.Path]::GetTempPath()) ("pet-insurance-{0}.zip" -f [guid]::NewGuid())
$remoteScript = Join-Path ([IO.Path]::GetTempPath()) ("publish-mcp-{0}.ps1" -f [guid]::NewGuid())
try {
    Compress-Archive -Path (Join-Path $root 'src\pet-insurance\*') -DestinationPath $zip
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
$package = Join-Path $env:TEMP 'pet-insurance.zip'
[IO.File]::WriteAllBytes($package, [Convert]::FromBase64String('__PACKAGE__'))
try {
    & $az login --identity --allow-no-subscriptions --output none
    if ($LASTEXITCODE -ne 0) { throw 'Managed identity login failed.' }
    & $az functionapp deployment source config-zip --subscription '__SUBSCRIPTION__' --resource-group '__GROUP__' --name '__APP__' --src $package --build-remote true --timeout 1200 --output none
    if ($LASTEXITCODE -ne 0) { throw 'Private MCP deployment failed.' }
    Write-Output 'PRIVATE_MCP_PUBLISH_SUCCEEDED'
} finally {
    Remove-Item $package -ErrorAction SilentlyContinue
}
'@
    $script = $script.Replace('__PACKAGE__', $payload).Replace('__SUBSCRIPTION__', $SubscriptionId).
        Replace('__GROUP__', $outputs.resourceGroupName.value).Replace('__APP__', $outputs.functionName.value)
    Set-Content $remoteScript $script
    $result = az vm run-command invoke --subscription $SubscriptionId --resource-group $outputs.resourceGroupName.value `
        --name $outputs.vmName.value --command-id RunPowerShellScript --scripts "@$remoteScript" --output json
    if ($LASTEXITCODE -ne 0) { throw 'VM deployment command failed.' }
    $messages = (($result | ConvertFrom-Json).value.message -join "`n")
    Write-Output $messages
    if ($messages -notmatch 'PRIVATE_MCP_PUBLISH_SUCCEEDED') { throw 'Private MCP publish did not report success.' }
} finally {
    Remove-Item $zip, $remoteScript -ErrorAction SilentlyContinue
}
