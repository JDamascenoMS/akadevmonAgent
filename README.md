# Agency Azure Development VM Agent

This repository contains an Agency-compatible GitHub Copilot agent that plans and provisions a private Azure Windows development VM. It installs selected .NET SDKs and Visual Studio 2022 workloads, enables Microsoft Entra sign-in, assigns VM-scoped login roles, and configures auto-shutdown.

It can run directly as a repository agent or be installed as an Agency/Copilot plugin.

## Safety model

- The VM attaches to an existing private subnet and receives no public IP or new NSG.
- Configuration is strict JSON; arbitrary commands, scripts, package sources, and package identifiers are rejected.
- Planning performs Azure preflight checks but changes nothing.
- Apply requires the SHA-256 hash of the exact reviewed command plan.
- The hash also covers the VM-side installation script, so changing it invalidates approval.
- A strong local bootstrap password is generated only in memory for Azure VM creation. It is not read from configuration or printed. The local bootstrap account is disabled after toolchain installation succeeds.
- Toolchain setup uses managed Run Command with a four-hour timeout to accommodate Visual Studio workloads.
- Provisioning stops on the first failure and reports partial state. It never silently deletes resources.

## Prerequisites

- Agency with the GitHub Copilot engine.
- PowerShell 7.
- Azure CLI authenticated to the configured tenant (`az login --tenant <tenant-id>`).
- Azure permissions to create the VM and related resources, install VM extensions, and create VM-scoped role assignments.
- An existing VNet and subnet with approved private client connectivity, private name resolution, and outbound HTTPS access for Azure/Entra endpoints, `dot.net`, `aka.ms`, and Visual Studio downloads.
- Same-tenant Entra user or group object IDs. Guest accounts cannot sign in through `AADLoginForWindows`.

The provisioning identity generally needs VM/resource creation rights and `Microsoft.Authorization/roleAssignments/write`. A user needs `Virtual Machine Administrator Login` or `Virtual Machine User Login`; Owner or Contributor alone does not grant VM sign-in.

## Configure

Copy [`.agency/azure-dev-vm.example.json`](.agency/azure-dev-vm.example.json) to `.agency/azure-dev-vm.json` and replace every example identifier. The contract is [`.agency/azure-dev-vm.schema.json`](.agency/azure-dev-vm.schema.json).

Supported SDK package IDs:

- `Microsoft.DotNet.SDK.8`
- `Microsoft.DotNet.SDK.9`
- `Microsoft.DotNet.SDK.10`

The schema also allowlists Visual Studio editions, workloads, and components. Extend both the schema and VM-side allowlist in a reviewed change if another tool is needed; never put an installer command in configuration.

## Run through Agency

From this repository:

```powershell
agency copilot --agent azure-dev-vm
```

Ask the agent to provision the VM described by `.agency/azure-dev-vm.json`. It will run preflight, show the full Azure CLI plan and plan hash, and request explicit approval before applying it.

The existing GitHub MCP server may remain enabled. It is not used for Azure provisioning, and no additional MCP server is required.

## Test as a local plugin

From a separate Git repository containing `.agency/azure-dev-vm.json`, load this checkout as a plugin:

```powershell
agency copilot `
  --plugin local:C:\path\to\agent-devtests `
  --agent agent-devtests:azure-dev-vm
```

For a local plugin, the namespace is the checkout directory name (`agent-devtests` above). The plugin uses `COPILOT_PLUGIN_ROOT` for its bundled scripts and reads configuration from the consumer repository.

## Publish to an Agency marketplace

This repository includes:

- `.github/plugin/plugin.json`, the Copilot plugin manifest.
- `.claude-plugin/plugin.json`, the Claude plugin manifest. Copilot accepts any one of the manifests, but the Claude engine requires this specific file, and both `agency plugin install` and `agency marketplace add` target every engine unless `--engine` is passed.
- `.claude-plugin/marketplace.json`, a catalog contributing the plugin.
- `agents/azure-dev-vm.md`, the plugin agent definition. It is intentionally kept identical to the repository-agent definition under `.github/agents`.

Agency acquires GitHub-hosted plugins through the GitHub CLI, not through Git's credential helper. Install and authenticate `gh` first, otherwise installation fails with `No GitHub accounts found`:

```powershell
winget install --id GitHub.cli
gh auth login --web --hostname github.com --git-protocol ssh --skip-ssh-key --clipboard
```

After pushing the repository to an approved GitHub organization, test direct installation:

```powershell
agency plugin install github:<org>/<repo>:. --engine copilot
agency plugin list --engine copilot
agency copilot --agent azure-dev-vm:azure-dev-vm
```

Consumers can register the repository as a custom marketplace:

```powershell
agency marketplace add --marketplace <org>/<repo> --engine copilot
```

Publication to Agency's curated company marketplace requires review and a change to the internally owned curated marketplace repository; the Agency CLI intentionally has no direct publish command.

## Run the provisioner directly

Plan with live Azure validation:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-AzureDevVm.ps1 `
  -ConfigPath .\.agency\azure-dev-vm.json `
  -Plan
```

Apply only the exact reviewed plan:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-AzureDevVm.ps1 `
  -ConfigPath .\.agency\azure-dev-vm.json `
  -Apply `
  -ExpectedPlanHash <64-character-plan-hash>
```

`-Offline` exists only for local tests and example generation. It skips Azure validation and must not be used as evidence that a real deployment is ready.

## Connect

The VM uses `AADLoginForWindows` and a system-assigned managed identity. For passwordless RDP, use a supported Windows client, select **Use a web account to sign in to the remote computer**, and connect using a private DNS hostname that matches the Entra device name. The web-account flow does not accept an IP address.

The client must reach the private subnet through an approved corporate connection. Conditional Access and tenant policy still apply.

## Troubleshoot and lifecycle

Inspect the VM and extensions:

```powershell
az vm show --resource-group <resource-group> --name <vm-name> --show-details
az vm extension show --resource-group <resource-group> --vm-name <vm-name> --name AADLoginForWindows
az vm get-instance-view --resource-group <resource-group> --name <vm-name>
```

Stop compute charges while retaining disks:

```powershell
az vm deallocate --resource-group <resource-group> --name <vm-name>
```

Deletion is intentionally outside the agent workflow. Review all resources in the target resource group before deleting the VM or resource group.

## Test

Tests mock no Azure service because they exercise local validation and deterministic planning only:

```powershell
Invoke-Pester .\tests\Invoke-AzureDevVm.Tests.ps1
```
