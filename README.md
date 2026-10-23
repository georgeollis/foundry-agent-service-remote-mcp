# Private Microsoft Foundry and pet-insurance MCP

A reproducible development environment based on Microsoft Foundry **sample 15**:
two peered virtual networks, private service endpoints, shared DNS, NAT egress,
a Windows 11 workstation behind Azure Bastion, and a Python MCP server on Azure
Functions Flex Consumption.

**Important:** this keeps sample 15, not sample 19. A Foundry MCP connection is
registered, but sample 15 does **not** support calling this private MCP endpoint
from its agent runtime. The workstation can reach and exercise the MCP server.
Peering and creating a connection do not remove that service limitation.

## Deploy to Azure

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fgeorgeollis%2Ffoundry-connections%2Fmain%2Fazuredeploy.json)

Deploy the infrastructure from Azure Portal, without running Bicep locally:

1. Check the [permissions, providers, quota, and licensing prerequisites](docs/deployment.md#prerequisites).
2. Click the button, choose your subscription, and enter a new environment name,
   your Entra **user object ID**, and a strong VM administrator password. Keep the
   regional/model defaults unless you intend to change them.
3. Review the billable resources and select **Review + create**. After deployment
   succeeds, copy its subscription deployment name and run the
   [single completion command](docs/deployment.md#azure-portal-button).

**The button provisions infrastructure, not the MCP application package.**
The completion command publishes MCP from the private VM and verifies it.
No public Function access is enabled. For scripted provisioning instead, use
the [PowerShell quick start](#quick-start).

## Architecture

```mermaid
flowchart TB
    operator["Operator"]
    internet["Public internet<br/>Outbound destinations"]
    dns["13 shared private DNS zones<br/>Linked to both VNets"]

    subgraph foundryVnet["Foundry VNet - 10.80.0.0/16"]
        bastion["Standard Bastion<br/>Public HTTPS 443"]
        vm["Windows 11 workstation<br/>No public IP"]
        agent["Delegated agent subnet"]
        foundryPe["Foundry private endpoint"]
        dependencyPe["Storage / Cosmos / Search / ACR<br/>Private endpoints"]
        monitorPe["Azure Monitor<br/>Private endpoint"]
        natA["NAT gateway A"]
        bastion -->|"Private RDP"| vm
        vm -->|"Private HTTPS"| foundryPe
        agent --> dependencyPe
        agent --> monitorPe
        agent --> natA
        vm --> natA
    end

    subgraph mcpVnet["MCP VNet - 10.81.0.0/16"]
        mcpPe["Function site private endpoint"]
        storagePe["Blob and Queue<br/>Private endpoints"]
        integration["Delegated Function<br/>integration subnet"]
        natB["NAT gateway B"]
        integration --> storagePe
        integration --> natB
    end

    subgraph managed["Managed services - public workload access disabled"]
        foundry["Microsoft Foundry<br/>Project and GPT-4.1"]
        dependencies["Foundry Storage / Cosmos DB<br/>Search / Container Registry"]
        monitor["Application Insights<br/>Log Analytics and AMPLS"]
        func["Flex Consumption<br/>Pet-insurance MCP"]
        storage["Function storage<br/>Managed identity"]
    end

    operator -->|"Public HTTPS - approved exception"| bastion
    vm -->|"Private HTTPS across VNet peering"| mcpPe
    foundryPe --> foundry
    foundry -->|"Agent network injection"| agent
    dependencyPe --> dependencies
    monitorPe --> monitor
    mcpPe --> func
    func -->|"Outbound VNet integration"| integration
    storagePe --> storage
    natA --> internet
    natB --> internet
    dns -.-> foundryVnet
    dns -.-> mcpVnet
```

The VNets are peered in both directions. Managed services are shown outside the
VNet boundaries: their **private endpoints**, not the services themselves, reside
in the subnets. There is deliberately no agent-to-MCP execution arrow.

| Component | Configuration |
|---|---|
| Regions | Sweden Central; Search only in Norway East |
| Foundry | Standard agent setup, GPT-4.1, Entra authentication |
| Access | Standard Bastion and Windows 11 Pro 24H2, Trusted Launch |
| MCP | Python 3.12, Flex Consumption, four simulated insurance tools |
| Networking | Two VNets, two NAT gateways, nine private endpoints |
| Name resolution | Thirteen private DNS zones, each linked to both VNets |
| Monitoring | Private Azure Monitor ingestion and query |
| Authentication | Managed identities and resource-scoped RBAC |

See [networking and access](docs/architecture.md) for subnet, DNS, and identity
details, and [deployment and operations](docs/deployment.md) for the full runbook.

## Quick start

Requires **PowerShell 7.2+ on Windows**, Azure CLI with Bicep, permission to create
resources and role assignments, eligible Windows 11 licensing, and sufficient
quota. Review the [provider and quota prerequisites](docs/deployment.md#prerequisites)
first.

```powershell
git clone https://github.com/georgeollis/foundry-connections.git
Set-Location .\foundry-connections

$subscription = '<subscription-id>'
$environment = '<environment-name>'
$deployment = @{
    SubscriptionId = $subscription
    EnvironmentName = $environment
}
$outputs = ".azure\$subscription\$environment\deployment-outputs.json"

az account set --subscription $subscription
.\scripts\Deploy.ps1 @deployment -Action Validate
# Review .azure\<subscription-id>\<environment-name>\what-if.json.
.\scripts\Deploy.ps1 @deployment -Action Deploy
.\scripts\Publish-Mcp.ps1 -SubscriptionId $subscription -OutputsPath $outputs
.\scripts\Test-Deployment.ps1 -SubscriptionId $subscription -OutputsPath $outputs
```

Validation writes a local receipt bound to the subscription, tenant, environment,
deployment name, source files, and effective parameters. Deployment rejects a
missing or mismatched receipt. No Copilot-specific files are needed.

When adopting an existing portal-created MCP connection, add
`McpConnectionName = '<existing-connection-name>'` to `$deployment` **before both
validation and deployment**. New environments default to `pet-insurance-mcp`.

## Repository layout

```text
infra\
  main.bicep                  Subscription-scoped entrypoint
  main.bicepparam             Region and environment configuration
  modules\                   Network, access, Function, roles, MCP connection
  foundry\                   Trimmed, adapted upstream sample 15 modules
  sources.json               Pinned upstream source revisions
azuredeploy.json             Generated, self-contained portal deployment template
scripts\
  Build-PortalTemplate.ps1    Regenerate the portal template from Bicep
  Complete-PortalDeployment.ps1  Import portal outputs, publish MCP, verify
  Deploy.ps1                 Validate/what-if, provision, save outputs
  Publish-Mcp.ps1            Publish privately through the Windows VM
  Test-Deployment.ps1        Live networking, DNS, RBAC, and MCP checks
  Test-Deploy.ps1            Offline validation-gate regression checks
src\pet-insurance\           Upstream sample MCP application
docs\                       Architecture and deployment runbook
```

The Bicep entrypoint groups DNS zones by workload rather than relying on numeric
array slices. Unused additional-project templates are removed; the upstream
module layout, source revision, and license are retained.

## Boundaries and costs

- **Bastion HTTPS is public by design.** There is no public RDP, and workload,
  storage, and monitoring access is private.
- Function outbound traffic uses VNet integration and NAT. This also allows its
  host/deployment storage to remain private; outbound was not left unintegrated.
- The MCP connection uses `RemoteTool`, anonymous authentication, custom MCP
  metadata, and disabled sharing. The endpoint is anonymous **inside the private
  network**, not a production authorization boundary.
- Pet-insurance tools return simulated data. This is a development/POC sample,
  not a production insurance service.
- Bastion, NAT, Search, Cosmos DB, registry, private endpoints, storage, disks,
  the VM, and model usage incur charges. Stopping the VM does not stop the other
  charges.

All deployment state, credentials, logs, and concrete environment identifiers
stay in ignored local files under `.azure\`. The published `azuredeploy.json`
is compiled from Bicep without environment parameters or credentials.
Documentation uses placeholders instead of deployed resource names.

## Attribution

Based on Microsoft's [Foundry sample 15](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup)
and Azure Samples' [pet-insurance MCP server](https://github.com/Azure-Samples/AI-Gateway/tree/main/labs/ai-foundry-toolbox/mcp-servers/pet-insurance).
See [NOTICE](NOTICE) and the preserved licenses. This repository is MIT licensed.
