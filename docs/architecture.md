# Networking and access

## Traffic paths

The [README diagram](../README.md#architecture) separates private endpoints
inside the VNets from the managed services they expose.

| Path | Behavior |
|---|---|
| Operator to workstation | Public HTTPS to Standard Bastion, then private RDP; no public VM IP |
| Workstation to Foundry | HTTPS to the Foundry account's private endpoint |
| Workstation to MCP | Peering routes HTTPS to the Function private endpoint |
| Agent to dependencies | Network injection into the delegated agent subnet, then private endpoints |
| Agent to MCP | Private HTTPS across VNet peering to the Function private endpoint |
| Agent to OpenAPI | Private HTTPS across VNet peering to the separate REST Function private endpoint |
| Function to storage | Outbound VNet integration, private Blob/Queue DNS and endpoints |
| Workload to internet | Its own VNet's NAT gateway |
| Monitoring | Azure Monitor Private Link Scope (AMPLS), private ingestion and query |

VNet peering is bidirectional, without gateway transit or forwarded traffic.
NAT gateways do not transit peering and do not provide unsolicited inbound
connectivity. The workstation NSG allows RDP only from the Bastion subnet.

## Address plan

| VNet | Subnet | Prefix | Purpose |
|---|---|---|---|
| Foundry | Agent | `10.80.0.0/24` | Delegated to `Microsoft.App/environments`; NAT A |
| Foundry | Private endpoints | `10.80.1.0/24` | Foundry, dependencies, and Monitor |
| Foundry | Workstation | `10.80.2.0/24` | Windows VM, NSG, NAT A |
| Foundry | Bastion | `10.80.3.0/26` | Required dedicated Bastion subnet |
| MCP / OpenAPI | Private endpoints | `10.81.0.0/24` | Two Function sites and each app's Blob/Queue |
| MCP / OpenAPI | Function integration | `10.81.1.0/24` | Shared by both apps; delegated to `Microsoft.App/environments`; NAT B |

The VNet address spaces are `10.80.0.0/16` and `10.81.0.0/16`.
Check for overlap before connecting this environment to other networks.

## Private DNS and endpoints

Every zone is linked to **both VNets**. Peering alone does not make a private DNS
zone visible to the peer. Automatic VM registration is disabled.

| Group | Zones |
|---|---|
| Foundry | `privatelink.services.ai.azure.com`, `privatelink.openai.azure.com`, `privatelink.cognitiveservices.azure.com` |
| Dependencies | `privatelink.search.windows.net`, `privatelink.blob.core.windows.net`, `privatelink.documents.azure.com`, `privatelink.azurecr.io` |
| Monitor | `privatelink.monitor.azure.com`, `privatelink.oms.opinsights.azure.com`, `privatelink.ods.opinsights.azure.com`, `privatelink.agentsvc.azure-automation.net` |
| Function | `privatelink.azurewebsites.net`, `privatelink.queue.core.windows.net` |

There are twelve private endpoints: Foundry, Foundry Blob, Cosmos DB, Search,
registry, Monitor, plus separate site, Blob, and Queue endpoints for each of
the MCP and OpenAPI Functions. Both apps reuse the existing thirteen DNS zones.

The shared Blob zone is also attached to the **Monitor private endpoint's DNS
zone group**. Merely linking that zone to the VNet does not populate Monitor's
content-storage records. Function site and SCM records use the same site private
endpoint.

Search is in Norway East because Sweden Central lacked physical capacity during
the original deployment. Its private endpoint remains in the Sweden Central
Foundry VNet. This regional split is configurable, not a promise of capacity.

## Identity and credentials

| Identity | Access |
|---|---|
| Each Function's user-assigned identity | Blob Data Owner and Queue Data Contributor on its own storage account |
| VM system-assigned identity | Website Contributor on each Function, for private publishing |
| Operator | Foundry User on the account, VM Administrator Login on the VM, Blob Reader on Function storage |
| Foundry project identity | Scoped Storage, Search, Cosmos DB, registry pull, and monitoring roles from sample 15 |

Storage does not allow shared keys or anonymous blobs. The VM's local
administrator password is generated and stored only in a local DPAPI-encrypted
credential file. It is not an output or source parameter. Decryption requires the
same Windows user on the same machine; do not publish even the encrypted file.

The Foundry MCP connection is declared at account and project scope to mirror
the portal-created configuration. Its URL is derived from the Function hostname.
The newer connection API supports the `RemoteTool` category; the upstream agent
infrastructure otherwise retains its original APIs.

The REST API is a separate Function, FC1 plan, storage account, and managed
identity. It shares the tools VNet, integration subnet, NAT gateway, and DNS
zones with MCP. Anonymous HTTP is intentional for this private-network demo;
it is not suitable as authorization for sensitive data. An anonymous OpenAPI
project connection is configured when importing the tool in Foundry.

## Monitoring and egress

Function telemetry is not wired to an unreachable private ingestion endpoint.
The Foundry tracing resources retain private ingestion and query. Internet
egress is through NAT, but this is not an outbound filtering firewall.
