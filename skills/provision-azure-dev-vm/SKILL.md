---
name: provision-azure-dev-vm
description: >
  Plan and provision a private Azure Windows development VM with Microsoft
  Entra sign-in, repository-approved .NET SDKs, and Visual Studio workloads.
  USE FOR: creating a Windows development workstation in an existing private
  Azure subnet, validating Azure prerequisites and permissions, reviewing the
  exact Azure CLI plan, or applying a previously approved plan hash. Requires
  a repository-owned .agency/azure-dev-vm.json configuration and explicit
  approval before creating billable resources. DO NOT USE FOR: public-IP VMs,
  creating or modifying networks, Linux VMs, arbitrary installation scripts,
  unattended provisioning without approval, or deleting Azure resources.
license: MIT
---

# Provision Azure Development VM

Use the plugin's bundled provisioner to create one private Windows development
VM from `.agency/azure-dev-vm.json` in the current repository.

## Safety contract

- Never create a public IP, NSG, VNet, subnet, route, DNS zone, firewall rule,
  or private endpoint.
- Never add arbitrary commands, scripts, package sources, SDK package IDs,
  Visual Studio workloads, or Visual Studio components to the configuration.
- Never use `-Offline` for a real deployment.
- Never run apply mode until the user explicitly approves the exact current
  plan hash.
- Never expose the runtime bootstrap password or bypass schema, preflight,
  signature, hash, tenant, subscription, quota, permission, or collision
  checks.
- Never claim success unless apply mode completes successfully.
- Never delete or silently clean up partially created resources.

## Prerequisites

- Windows x64 with PowerShell 7, Azure CLI, Agency, and GitHub Copilot.
- Azure CLI authenticated to the configured tenant.
- Permission to create the configured VM resources, install VM extensions,
  join the existing subnet, and create VM-scoped role assignments.
- An existing private VNet and subnet with approved connectivity, private DNS,
  and outbound HTTPS access for Azure, Microsoft Entra, .NET, and Visual Studio
  endpoints.
- Same-tenant Microsoft Entra user or group object IDs. Guest accounts are not
  supported by `AADLoginForWindows`.

## Locate bundled files

Agency runs commands from the consumer repository, not from the installed
plugin directory. Resolve every bundled file through `COPILOT_PLUGIN_ROOT`:

```powershell
if ([string]::IsNullOrWhiteSpace($env:COPILOT_PLUGIN_ROOT)) {
    throw 'COPILOT_PLUGIN_ROOT is unavailable; the Agency plugin was not loaded correctly.'
}
$provisioner = Join-Path $env:COPILOT_PLUGIN_ROOT 'scripts\Invoke-AzureDevVm.ps1'
$exampleConfig = Join-Path $env:COPILOT_PLUGIN_ROOT '.agency\azure-dev-vm.example.json'
$configPath = Join-Path (git rev-parse --show-toplevel) '.agency\azure-dev-vm.json'
```

Do not resolve the provisioner or schema from an identically named path in the
consumer repository.

## Configure

If `.agency/azure-dev-vm.json` does not exist, offer to copy the bundled example
to that path:

```powershell
New-Item -ItemType Directory -Force -Path (Split-Path $configPath) | Out-Null
Copy-Item -LiteralPath $exampleConfig -Destination $configPath
```

Stop after copying. Ask the user to replace every example tenant, subscription,
resource, network, and principal identifier and to review the requested
toolchain. Never invent those values.

The strict schema allows:

- Windows 11 Enterprise, Windows Server 2022, or Windows Server 2025 images
  supported by Microsoft Entra sign-in.
- An existing private subnet only, with no public IP and no new NSG.
- VM-scoped `Virtual Machine Administrator Login` or
  `Virtual Machine User Login` assignments.
- Allowlisted .NET SDK package IDs and Visual Studio 2022
  editions/workloads/components.
- Automatic shutdown.

## Plan

Run live validation and generate the command plan:

```powershell
pwsh -NoProfile -File $provisioner -ConfigPath $configPath -Plan
```

If validation or Azure preflight fails, report the exact error and stop. Do not
retry with weaker checks.

Present:

- tenant, subscription, resource group, region, VM name/image/size, and disk;
- existing VNet and subnet, emphasizing that no public IP or NSG is created;
- Entra principals and VM login roles;
- SDKs, Visual Studio edition/workloads/components, and auto-shutdown;
- every generated Azure CLI command without alteration;
- billable-resource and partial-failure implications;
- the exact 64-character plan hash.

Then use the user-input tool to request explicit approval of that exact hash.
The initial provisioning request or a generic "go ahead" is not approval of the
generated plan.

## Apply an approved plan

Only after exact-hash approval:

```powershell
pwsh -NoProfile -File $provisioner `
  -ConfigPath $configPath `
  -Apply `
  -ExpectedPlanHash <approved-64-character-plan-hash>
```

The provisioner regenerates the plan and rejects changed configuration,
commands, or VM-side installer content. If the hash changes, return to the plan
step and request new approval.

Monitor apply mode to completion. On failure, report its completed-step list and
partial-resource warning. Do not automatically retry, delete, or recreate
resources.

## Report success

Report:

- VM resource ID and provisioning status;
- installed .NET SDKs and Visual Studio configuration;
- Microsoft Entra login role assignments;
- private hostname/DNS and supported RDP client requirements;
- auto-shutdown configuration;
- the reviewed plan hash.

Explain that Owner or Contributor alone does not grant VM sign-in. Passwordless
RDP's web-account flow requires a network-resolvable hostname rather than an IP
address.

Show deallocation only as an optional, separately reviewed lifecycle command:

```powershell
az vm deallocate --resource-group <resource-group> --name <vm-name>
```

Deletion remains outside this skill.
