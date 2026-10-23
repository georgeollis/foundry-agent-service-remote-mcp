# Microsoft Foundry Agent Service - Remote MCP

A reproducible development environment based on Microsoft Foundry **sample 15**:
two peered virtual networks, private service endpoints, shared DNS, NAT egress,
a Windows 11 workstation behind Azure Bastion, and separate Python MCP and
OpenAPI services on Azure Functions Flex Consumption.

## Deploy to Azure

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fgeorgeollis%2Ffoundry-agent-service-remote-mcp%2Fmain%2Fazuredeploy.json)

Deploy the infrastructure from Azure Portal, without running Bicep locally:

1. Check the [permissions, providers, quota, and licensing prerequisites](docs/deployment.md#prerequisites).
2. Click the button, choose your subscription, and enter a new environment name,
   your Entra **user object ID**, and a strong VM administrator password. Keep the
   regional/model defaults unless you intend to change them.
3. Review the billable resources and select **Review + create**. After deployment
   succeeds, copy its subscription deployment name and run the
   [single completion command](docs/deployment.md#azure-portal-button).

**The button provisions infrastructure, not the Function application packages.**
The completion command publishes both services from the private VM and verifies them.
No public Function access is enabled. For scripted provisioning instead, use
the [PowerShell quick start](#quick-start).

## Architecture

The Foundry agent calls private pet-insurance services using either MCP or an
OpenAPI tool across the peered VNets. Both Functions disable public workload access.

```mermaid
flowchart LR
    subgraph foundryVnet["Foundry VNet"]
        agent["Foundry agent<br/>Network-injected subnet"]
    end
    subgraph mcpVnet["MCP / OpenAPI VNet"]
        endpoint["MCP Function<br/>Private endpoint"]
        apiEndpoint["OpenAPI Function<br/>Private endpoint"]
    end
    server["Pet-insurance MCP<br/>Functions Flex Consumption"]
    apiServer["Pet-insurance REST API<br/>OpenAPI 3.0.3"]

    agent ==>|"MCP tool calls<br/>Private HTTPS over VNet peering"| endpoint
    endpoint ==>|"Private HTTPS"| server
    agent ==>|"OpenAPI tool calls<br/>Private HTTPS over VNet peering"| apiEndpoint
    apiEndpoint ==>|"Private HTTPS"| apiServer

    classDef agent fill:#DBEAFE,stroke:#1D4ED8,stroke-width:3px,color:#0F172A
    classDef mcp fill:#CCFBF1,stroke:#0F766E,stroke-width:3px,color:#0F172A
    classDef api fill:#E0E7FF,stroke:#4338CA,stroke-width:3px,color:#0F172A
    class agent agent
    class endpoint,server mcp
    class apiEndpoint,apiServer api
    style foundryVnet fill:#F8FAFC,stroke:#2563EB,stroke-width:2px
    style mcpVnet fill:#F0FDFA,stroke:#0F766E,stroke-width:2px
```

<details>
<summary>Full architecture: private endpoints, administration, DNS, and NAT egress</summary>

```mermaid
flowchart TB
    operator["Operator"]:::external
    dns["Shared private DNS<br/>13 zones linked to both VNets"]:::dns

    subgraph networks["Private network - Sweden Central"]
        subgraph foundryVnet["Foundry VNet - 10.80.0.0/16"]
            bastion["Standard Bastion"]:::access
            vm["Windows 11 workstation<br/>No public IP"]:::access
            agent["Foundry agent<br/>Network-injected agent subnet"]:::agent
            foundryPe["Foundry<br/>Private endpoint"]:::endpoint
            dependencyPe["Storage / Cosmos / Search / ACR<br/>4 private endpoints"]:::endpoint
            monitorPe["Azure Monitor<br/>Private endpoint"]:::endpoint
            natA["NAT Gateway A"]:::egress
        end

        subgraph mcpVnet["MCP / OpenAPI VNet - 10.81.0.0/16"]
            mcpPe["MCP Function<br/>Private endpoint"]:::mcp
            apiPe["OpenAPI Function<br/>Private endpoint"]:::api
            storagePe["MCP + OpenAPI Blob / Queue<br/>4 private endpoints"]:::endpoint
            integration["Both Functions outbound<br/>Shared integration subnet"]:::endpoint
            natB["NAT Gateway B"]:::egress
        end
    end

    subgraph managed["Azure managed services - public workload access disabled"]
        foundry["Microsoft Foundry<br/>Project + GPT-4.1"]:::service
        dependencies["Foundry Storage / Cosmos DB / ACR<br/>AI Search in Norway East"]:::service
        monitor["Application Insights + Log Analytics<br/>Azure Monitor Private Link Scope"]:::service
        func["Pet-insurance MCP server<br/>Functions Flex Consumption - Python 3.12"]:::mcp
        api["Pet-insurance REST API<br/>OpenAPI 3.0.3 - Python 3.12"]:::api
        storage["Separate MCP / OpenAPI storage accounts<br/>Managed identity access"]:::service
    end

    internet["Public internet<br/>Outbound destinations only"]:::external

    operator -->|"Public HTTPS 443<br/>Bastion exception"| bastion
    bastion -->|"Private RDP"| vm
    vm -->|"Private HTTPS"| foundryPe
    vm -->|"Administration / testing<br/>VNet peering"| mcpPe
    agent ==>|"MCP tool calls<br/>Private HTTPS over VNet peering"| mcpPe
    mcpPe ==>|"Private inbound HTTPS"| func
    vm -->|"Administration / testing<br/>VNet peering"| apiPe
    agent ==>|"OpenAPI tool calls<br/>Private HTTPS over VNet peering"| apiPe
    apiPe ==>|"Private inbound HTTPS"| api

    foundryPe --> foundry
    foundry -->|"Agent network injection"| agent
    agent --> dependencyPe
    dependencyPe --> dependencies
    agent --> monitorPe
    monitorPe --> monitor

    func -->|"Outbound VNet integration"| integration
    api -->|"Outbound VNet integration"| integration
    integration -->|"Private storage access"| storagePe
    storagePe --> storage

    agent --> natA
    vm --> natA
    integration --> natB
    natA -->|"Outbound only"| internet
    natB -->|"Outbound only"| internet

    dns -.-> foundryVnet
    dns -.-> mcpVnet

    classDef agent fill:#DBEAFE,stroke:#1D4ED8,stroke-width:3px,color:#0F172A
    classDef mcp fill:#CCFBF1,stroke:#0F766E,stroke-width:3px,color:#0F172A
    classDef api fill:#E0E7FF,stroke:#4338CA,stroke-width:3px,color:#0F172A
    classDef endpoint fill:#EFF6FF,stroke:#3B82F6,color:#0F172A
    classDef service fill:#F8FAFC,stroke:#64748B,color:#0F172A
    classDef access fill:#F3E8FF,stroke:#9333EA,color:#0F172A
    classDef egress fill:#FFF7ED,stroke:#EA580C,color:#0F172A
    classDef dns fill:#F0FDF4,stroke:#16A34A,color:#0F172A
    classDef external fill:#FFFFFF,stroke:#64748B,color:#0F172A
    style networks fill:#FFFFFF,stroke:#CBD5E1
    style foundryVnet fill:#F8FAFC,stroke:#2563EB,stroke-width:2px
    style mcpVnet fill:#F0FDFA,stroke:#0F766E,stroke-width:2px
    style managed fill:#F8FAFC,stroke:#94A3B8,stroke-dasharray:5 5
```

**Private tool paths:** Foundry agent -> VNet peering -> the tool's Function
private endpoint -> MCP server or REST API. The bold arrows highlight these tool calls; the
workstation has a separate administration and testing path.

The VNets are peered in both directions. Dashed arrows represent DNS links;
orange nodes are outbound-only NAT gateways, one per VNet. Managed services sit
outside the VNet boundaries: their **twelve private endpoints** reside inside.

</details>

| Component | Configuration |
|---|---|
| Regions | Sweden Central; Search only in Norway East |
| Foundry | Standard agent setup, GPT-4.1, Entra authentication |
| Access | Standard Bastion and Windows 11 Pro 24H2, Trusted Launch |
| MCP | Python 3.12, Flex Consumption, four simulated insurance tools |
| OpenAPI | Separate Flex Function, OpenAPI 3.0.3, three simulated REST operations |
| Networking | Two VNets, two NAT gateways, twelve private endpoints |
| Name resolution | Thirteen private DNS zones, each linked to both VNets |
| Monitoring | Private Azure Monitor ingestion and query |
| Authentication | Managed identities and resource-scoped RBAC |

See [networking and access](docs/architecture.md) for subnet, DNS, and identity
details, and [deployment and operations](docs/deployment.md) for the full runbook.
For the API contract and Foundry import steps, see
[using the OpenAPI tool](docs/deployment.md#openapi-tool-in-foundry).

## Quick start

Requires **PowerShell 7.2+ on Windows**, Azure CLI with Bicep, permission to create
resources and role assignments, eligible Windows 11 licensing, and sufficient
quota. Review the [provider and quota prerequisites](docs/deployment.md#prerequisites)
first.

```powershell
git clone https://github.com/georgeollis/foundry-agent-service-remote-mcp.git
Set-Location .\foundry-agent-service-remote-mcp

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
.\scripts\Publish-Functions.ps1 -SubscriptionId $subscription -OutputsPath $outputs
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
  modules\                   Network, access, Function, roles, tool connections
  foundry\                   Trimmed, adapted upstream sample 15 modules
  sources.json               Pinned upstream source revisions
azuredeploy.json             Generated, self-contained portal deployment template
scripts\
  Build-PortalTemplate.ps1    Regenerate the portal template from Bicep
  Complete-PortalDeployment.ps1  Import portal outputs, publish Functions, verify
  Deploy.ps1                 Validate/what-if, provision, save outputs
  Publish-Functions.ps1      Publish both services privately and export OpenAPI
  Publish-Mcp.ps1            Compatibility command for MCP-only publishing
  Test-Deployment.ps1        Live networking, DNS, RBAC, MCP, and REST checks
  Test-Deploy.ps1            Offline validation-gate regression checks
src\pet-insurance\           Upstream sample MCP application
src\pet-insurance-api\       REST Function and sample openapi.json
tests\                      OpenAPI contract and HTTP handler tests
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
- The REST API also uses anonymous HTTP authentication inside the private network.
  Bicep provisions its anonymous OpenAPI project connection with sharing disabled.
  Its OpenAPI spec contains no keys. Add authentication before using real data.
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
