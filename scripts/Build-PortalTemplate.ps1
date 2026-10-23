[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
az bicep build --file (Join-Path $root 'infra\main.bicep') --outfile (Join-Path $root 'azuredeploy.json') --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Portal ARM template compilation failed.' }
Write-Output 'Generated azuredeploy.json from infra\main.bicep.'
