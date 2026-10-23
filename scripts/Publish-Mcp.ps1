[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$OutputsPath
)

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Publish-Functions.ps1') -SubscriptionId $SubscriptionId -OutputsPath $OutputsPath -Service Mcp
