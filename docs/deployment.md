# Deployment and operations

## Prerequisites

Use PowerShell 7.2+ on Windows with Azure CLI and Bicep. The deployment script
uses Windows DPAPI for the workstation credential. The deploying user needs
Owner or equivalent resource and role-assignment permissions, eligible Windows
11 licensing, and access to GPT-4.1 in the chosen region.

Register the required resource providers in the target subscription:

```powershell
$subscription = '<subscription-id>'
az account set --subscription $subscription
$providers = @(
    'Microsoft.Network', 'Microsoft.Compute', 'Microsoft.Storage',
    'Microsoft.Web', 'Microsoft.CognitiveServices', 'Microsoft.Search',
    'Microsoft.DocumentDB', 'Microsoft.ContainerRegistry',
    'Microsoft.ManagedIdentity', 'Microsoft.Insights',
    'Microsoft.OperationalInsights', 'Microsoft.AlertsManagement',
    'Microsoft.App', 'Microsoft.ContainerService'
)
foreach ($provider in $providers) {
    az provider register --subscription $subscription --namespace $provider --wait
    if ($LASTEXITCODE -ne 0) { throw "Provider registration failed: $provider" }
}
```

Allow for at least two Dsv5 vCPUs, two VNets, two NAT gateways, three Standard
public IPs, nine private endpoints, two storage accounts, one Flex Consumption
plan, the Foundry agent environment, Search, Cosmos DB, registry, and GPT-4.1
GlobalStandard capacity 30. Inspect regional quota and effective Azure Policy
before deployment; ARM validation does not guarantee physical capacity.

An earlier subscription required
`Microsoft.Network/AllowBringYourOwnPublicIpAddress` even for Azure-allocated
public IPs. The deployment script retains its feature check/registration and
reports a pending registration rather than silently proceeding.

## Azure Portal button

The [Deploy to Azure button](../README.md#deploy-to-azure) opens a self-contained
ARM template in Azure Portal. The template's schema selects **subscription
scope**, and the template creates its own resource group.

Use a new environment name containing 3-40 lowercase letters, numbers, or
hyphens. Supply your Microsoft Entra **user object ID in the target tenant**,
not an email address or tenant ID. Find it in your Entra user profile, or run:

```powershell
az account set --subscription '<subscription-id>'
az ad signed-in-user show --query id --output tsv
```

Enter the VM administrator password in the portal's secure password field and
store it safely. Unlike the PowerShell provisioning path, portal deployment
does not create a local DPAPI credential file. Owner or equivalent permissions,
resource providers, quotas, licensing, and the Bastion public-HTTPS exception
still apply. The local CLI validation receipt is not used by Azure Portal;
the portal performs its own review and ARM validation.

After the subscription deployment succeeds, copy its deployment name from
**Subscription > Deployments**. Clone this repository on a Windows machine with
PowerShell 7.2+ and Azure CLI, sign in to Azure, and run:

```powershell
.\scripts\Complete-PortalDeployment.ps1 `
    -SubscriptionId '<subscription-id>' `
    -DeploymentName '<portal-deployment-name>'
```

This imports the actual outputs into the correct ignored environment directory,
starts the VM if necessary, publishes the MCP package through the private VM
using managed identity, and runs the existing live verification. It does not
reprovision infrastructure or require your VM password.

The infrastructure template alone does **not** publish the Function code, and
registering the MCP connection does not remove sample 15's private-tool
execution limitation.

### Maintaining the button

`azuredeploy.json` is generated from `infra\main.bicep`, not hand-edited. After
changing Bicep, regenerate and commit it with:

```powershell
.\scripts\Build-PortalTemplate.ps1
```

The public raw-template URL contains no subscription identifiers, operator IDs,
passwords, or environment-specific parameter values. Never build this artifact
from local deployment parameters or copy ignored state into it.

## Configure and deploy

Use the [README quick start](../README.md#quick-start). Change primary/Search
regions in `infra\main.bicepparam`; change model and VM defaults in
`infra\main.bicep` when needed. The subscription deployment record is stored in
Sweden Central; this metadata location is distinct from resource locations.

Use a fresh environment name when targeting a new subscription or independent
environment. The script resolves the operator in the selected tenant and keeps
each environment's state separate.

For a previously created MCP connection, set its existing name explicitly:

```powershell
$deployment = @{
    SubscriptionId = '<subscription-id>'
    EnvironmentName = '<environment-name>'
    McpConnectionName = '<existing-connection-name>'
}
.\scripts\Deploy.ps1 @deployment -Action Validate
.\scripts\Deploy.ps1 @deployment -Action Deploy
```

Use the same arguments for both commands. If a subscription deployment record
with the default name already has another location, add a distinct
`DeploymentName` to the hashtable rather than changing or deleting the existing
deployment.

Validation compiles Bicep/parameters, performs ARM validation, and saves a
what-if preview and receipt. Review the preview before deployment. The receipt's
fingerprint covers Bicep source and effective parameters without saving plaintext
credentials. Source, parameter, target, or deployment-name changes require
validation again. Explicitly rerun validation when reviewing Azure-side drift.

### Local state

Under `.azure\<subscription-id>\<environment-name>\`:

| File | Purpose |
|---|---|
| `vm-admin.credential.xml` | DPAPI-encrypted local VM administrator credential |
| `validation.json` | Successful validation receipt |
| `what-if.json` | Deployment preview |
| `deployment-outputs.json` | Actual resource identifiers and private service URLs |
| `verification.json` | Live verification result |

The entire `.azure\` tree is ignored by Git, including historical plans and logs.
Do not force-add it. A receipt is a local safety check, not signed attestation;
Azure RBAC and an appropriate review/approval process remain necessary.

## Private publishing and access

Connect to the Windows VM through Bastion to browse private endpoints.
Foundry project URLs have the form
`https://<foundry-account>.services.ai.azure.com/api/projects/<project>`.
MCP uses
`https://<function-app>.azurewebsites.net/runtime/webhooks/mcp`.

`Publish-Mcp.ps1` starts the VM when necessary and uses VM Run Command to publish
the Function ZIP. Azure CLI is installed inside the VM if absent. The VM signs in
using its managed identity; its Function-scoped role authorizes publishing.
Temporary packages/scripts are removed. Workload public access is never enabled.

Give publishing and verification the correct environment outputs path. Both
scripts reject outputs from another subscription.

## Verification

`Test-Deployment.ps1` checks peering, NAT associations, approved private
endpoints, both-VNet DNS links, private service/storage/monitoring access,
Windows 11 without a public IP, and live managed-identity roles. It then runs
private DNS and MCP initialization/list/tool-call checks inside the VM.

The four simulated tools are `check_coverage`, `request_pre_auth`,
`check_claim_status`, and `submit_claim_documents`. A successful VM test does not
establish that sample 15's agent runtime can reach private MCP.

For local source and validation-gate regression checks:

```powershell
az bicep build --file .\infra\main.bicep --stdout --only-show-errors > $null
if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed' }
.\scripts\Test-Deploy.ps1
```

## Recovery and cleanup

| Symptom | Action |
|---|---|
| Search `InsufficientResourcesAvailable` | Choose an approved supported Search region, update parameters, revalidate |
| Function publishing HTTP 403 | Check private Blob/Queue DNS, integration, NAT, and storage identity roles; do not enable public storage |
| Monitor Blob DNS missing | Check the Blob zone association on the Monitor endpoint DNS group |
| Foundry data plane unavailable locally | Use the Bastion workstation; a public DNS result from outside the VNets is not a private-path test |
| Validation receipt rejected | Rerun validation with unchanged intended arguments and review the new preview |

Deleting the environment is destructive and is intentionally not automated.
Consult the upstream sample's capability-host cleanup guidance before purging
Foundry resources. Deallocating the VM alone does not remove the other charges.
