Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SecretPlaceholder = '__AGENCY_VM_BOOTSTRAP_PASSWORD__'
$script:ReservedAdminNames = @(
    'administrator', 'admin', 'user', 'user1', 'test', 'user2', 'test1',
    'user3', 'admin1', '123', 'a', 'actuser', 'adm', 'admin2', 'aspnet',
    'backup', 'console', 'david', 'guest', 'john', 'owner', 'root', 'server',
    'sql', 'support', 'support_388945a0', 'sys', 'test2', 'test3'
)

function Assert-Config {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ConfigPath
    )

    $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $schemaPath = Join-Path $PSScriptRoot '..\.agency\azure-dev-vm.schema.json'
    $raw = Get-Content -LiteralPath $resolvedConfigPath -Raw

    try {
        $isValid = Test-Json -Json $raw -SchemaFile $schemaPath -ErrorAction Stop
    }
    catch {
        throw "Configuration schema validation failed: $($_.Exception.Message)"
    }

    if (-not $isValid) {
        throw 'Configuration does not conform to .agency/azure-dev-vm.schema.json.'
    }

    $config = $raw | ConvertFrom-Json -Depth 20
    if ($script:ReservedAdminNames -contains $config.vm.adminUsername.ToLowerInvariant()) {
        throw "vm.adminUsername '$($config.vm.adminUsername)' is reserved by Azure."
    }

    $duplicates = $config.access |
        Group-Object -Property principalObjectId |
        Where-Object Count -gt 1
    if ($duplicates) {
        throw "Each access principal may appear only once. Duplicate: $($duplicates[0].Name)"
    }

    return $config
}

function ConvertTo-DisplayArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)

    if ($Value -eq $script:SecretPlaceholder) {
        return '$env:AGENCY_VM_BOOTSTRAP_PASSWORD'
    }
    if ($Value.Length -eq 0) {
        return '""'
    }
    if ($Value -match '^[A-Za-z0-9_./:@=+\[\]-]+$') {
        return $Value
    }
    return "'$($Value.Replace("'", "''"))'"
}

function New-PlanCommand {
    param(
        [Parameter(Mandatory)][string] $Step,
        [Parameter(Mandatory)][AllowEmptyString()][string[]] $Arguments
    )

    $displayArguments = $Arguments | ForEach-Object { ConvertTo-DisplayArgument $_ }
    [pscustomobject]@{
        step       = $Step
        executable = 'az'
        arguments  = [string[]] $Arguments
        command    = "az $($displayArguments -join ' ')"
    }
}

function Get-ResourceIds {
    param([Parameter(Mandatory)][pscustomobject] $Config)

    $subscription = $Config.azure.subscriptionId.ToLowerInvariant()
    $resourceGroup = $Config.azure.resourceGroupName
    $vmName = $Config.vm.name
    $networkResourceGroup = $Config.network.vnetResourceGroupName
    $vnetName = $Config.network.vnetName
    $subnetName = $Config.network.subnetName

    [pscustomobject]@{
        Vm = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName"
        Subnet = "/subscriptions/$subscription/resourceGroups/$networkResourceGroup/providers/Microsoft.Network/virtualNetworks/$vnetName/subnets/$subnetName"
    }
}

function New-AzureDevVmPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Config
    )

    $ids = Get-ResourceIds -Config $Config
    $commands = [System.Collections.Generic.List[object]]::new()
    $installScriptPath = (Resolve-Path -LiteralPath (
        Join-Path $PSScriptRoot 'Install-DeveloperToolchain.ps1'
    )).Path
    $installScriptHash = (Get-FileHash -LiteralPath $installScriptPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $commands.Add((New-PlanCommand -Step 'Select subscription' -Arguments @(
        'account', 'set', '--subscription', $Config.azure.subscriptionId
    )))

    if ($Config.azure.createResourceGroup) {
        $groupArguments = @(
            'group', 'create',
            '--name', $Config.azure.resourceGroupName,
            '--location', $Config.azure.location,
            '--only-show-errors'
        )
        if ($Config.azure.tags) {
            $tagValues = $Config.azure.tags.psobject.Properties |
                Sort-Object Name |
                ForEach-Object { "$($_.Name)=$($_.Value)" }
            if ($tagValues.Count -gt 0) {
                $groupArguments += '--tags'
                $groupArguments += $tagValues
            }
        }
        $commands.Add((New-PlanCommand -Step 'Create or update resource group' -Arguments $groupArguments))
    }

    $vmArguments = @(
        'vm', 'create',
        '--resource-group', $Config.azure.resourceGroupName,
        '--name', $Config.vm.name,
        '--location', $Config.azure.location,
        '--image', $Config.vm.image,
        '--size', $Config.vm.size,
        '--os-disk-size-gb', [string]($Config.vm.osDiskSizeGb ?? 256),
        '--admin-username', $Config.vm.adminUsername,
        '--authentication-type', 'password',
        '--admin-password', $script:SecretPlaceholder,
        '--assign-identity', '[system]',
        '--security-type', 'TrustedLaunch',
        '--subnet', $ids.Subnet,
        '--public-ip-address', '',
        '--nsg', '',
        '--only-show-errors'
    )
    if ($Config.azure.tags) {
        $tagValues = $Config.azure.tags.psobject.Properties |
            Sort-Object Name |
            ForEach-Object { "$($_.Name)=$($_.Value)" }
        if ($tagValues.Count -gt 0) {
            $vmArguments += '--tags'
            $vmArguments += $tagValues
        }
    }
    $commands.Add((New-PlanCommand -Step 'Create private Windows VM' -Arguments $vmArguments))

    $commands.Add((New-PlanCommand -Step 'Enable Microsoft Entra sign-in' -Arguments @(
        'vm', 'extension', 'set',
        '--resource-group', $Config.azure.resourceGroupName,
        '--vm-name', $Config.vm.name,
        '--publisher', 'Microsoft.Azure.ActiveDirectory',
        '--name', 'AADLoginForWindows',
        '--version', '1.0',
        '--enable-auto-upgrade', 'true',
        '--only-show-errors'
    )))

    foreach ($assignment in ($Config.access | Sort-Object principalObjectId)) {
        $commands.Add((New-PlanCommand -Step "Grant $($assignment.role) to $($assignment.principalObjectId)" -Arguments @(
            'role', 'assignment', 'create',
            '--assignee-object-id', $assignment.principalObjectId,
            '--assignee-principal-type', $assignment.principalType,
            '--role', $assignment.role,
            '--scope', $ids.Vm,
            '--only-show-errors'
        )))
    }

    $commands.Add((New-PlanCommand -Step 'Configure automatic shutdown' -Arguments @(
        'vm', 'auto-shutdown',
        '--resource-group', $Config.azure.resourceGroupName,
        '--name', $Config.vm.name,
        '--time', $Config.autoShutdown.time,
        '--time-zone', $Config.autoShutdown.timeZone,
        '--only-show-errors'
    )))

    $visualStudio = $Config.toolchain.visualStudio
    $installParameters = @(
        "SdkPackages=$($Config.toolchain.sdkPackages -join ',')",
        "VisualStudioEdition=$($visualStudio.edition)",
        "VisualStudioWorkloads=$($visualStudio.workloads -join ',')",
        "VisualStudioComponents=$($visualStudio.components -join ',')",
        "IncludeRecommended=$([string]($visualStudio.includeRecommended ?? $true))",
        "AdminUsername=$($Config.vm.adminUsername)"
    )
    $installArguments = @(
        'vm', 'run-command', 'create',
        '--resource-group', $Config.azure.resourceGroupName,
        '--vm-name', $Config.vm.name,
        '--run-command-name', 'agency-install-toolchain',
        '--location', $Config.azure.location,
        '--script', "@$installScriptPath",
        '--parameters'
    ) + $installParameters + @(
        '--timeout-in-seconds', '14400',
        '--async-execution', 'false',
        '--only-show-errors'
    )
    $commands.Add((New-PlanCommand -Step 'Install the approved developer toolchain' -Arguments $installArguments))

    $artifacts = @(
        [pscustomobject]@{
            path   = 'scripts/Install-DeveloperToolchain.ps1'
            sha256 = $installScriptHash
        }
    )
    $hashInput = [ordered]@{
        commands  = @($commands | Select-Object step, executable, arguments)
        artifacts = $artifacts
    }
    $hashSource = $hashInput | ConvertTo-Json -Depth 10 -Compress
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData(
        [System.Text.Encoding]::UTF8.GetBytes($hashSource)
    )
    $planHash = [Convert]::ToHexString($hashBytes).ToLowerInvariant()

    [pscustomobject]@{
        schemaVersion = 1
        planHash      = $planHash
        resourceId    = $ids.Vm
        artifacts     = $artifacts
        commands      = $commands
    }
}

function Invoke-AzCommand {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]] $Arguments,
        [switch] $AllowNotFound
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object ToString) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        if ($AllowNotFound -and $exitCode -eq 3) {
            return $null
        }
        $secret = $env:AGENCY_VM_BOOTSTRAP_PASSWORD
        $safeArguments = $Arguments | ForEach-Object {
            if ($secret -and $_ -eq $secret) { '[REDACTED]' } else { $_ }
        }
        $safeText = if ($secret) { $text.Replace($secret, '[REDACTED]') } else { $text }
        throw "Azure CLI failed (exit $exitCode): az $($safeArguments -join ' ')`n$safeText"
    }
    return $text
}

function Assert-AzureActionsAllowed {
    param(
        [Parameter(Mandatory)][string] $Scope,
        [Parameter(Mandatory)][string[]] $RequiredActions
    )

    $url = "https://management.azure.com$Scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    $response = Invoke-AzCommand -Arguments @(
        'rest', '--method', 'get', '--url', $url, '--output', 'json', '--only-show-errors'
    ) | ConvertFrom-Json
    $permissions = @($response.value)

    foreach ($requiredAction in $RequiredActions) {
        $isAllowed = $false
        foreach ($permission in $permissions) {
            $included = @($permission.actions) |
                Where-Object { $requiredAction -like $_ } |
                Select-Object -First 1
            $excluded = @($permission.notActions) |
                Where-Object { $requiredAction -like $_ } |
                Select-Object -First 1
            if ($included -and -not $excluded) {
                $isAllowed = $true
                break
            }
        }
        if (-not $isAllowed) {
            throw "The signed-in identity does not have '$requiredAction' at scope '$Scope'."
        }
    }
}

function Invoke-AzurePreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $Config)

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) is required but was not found.'
    }

    $accountText = Invoke-AzCommand -Arguments @('account', 'show', '--output', 'json', '--only-show-errors')
    $account = $accountText | ConvertFrom-Json
    if ($account.state -ne 'Enabled') {
        throw "The current Azure CLI account is not enabled (state: $($account.state))."
    }
    if ($account.tenantId -ne $Config.azure.tenantId) {
        throw "Azure CLI tenant '$($account.tenantId)' does not match configured tenant '$($Config.azure.tenantId)'."
    }

    Invoke-AzCommand -Arguments @(
        'account', 'set', '--subscription', $Config.azure.subscriptionId
    ) | Out-Null
    $selected = (Invoke-AzCommand -Arguments @(
        'account', 'show', '--output', 'json', '--only-show-errors'
    )) | ConvertFrom-Json
    if ($selected.id -ne $Config.azure.subscriptionId) {
        throw "Unable to select configured subscription '$($Config.azure.subscriptionId)'."
    }

    $group = Invoke-AzCommand -Arguments @(
        'group', 'show', '--name', $Config.azure.resourceGroupName,
        '--output', 'json', '--only-show-errors'
    ) -AllowNotFound
    if (-not $group -and -not $Config.azure.createResourceGroup) {
        throw "Resource group '$($Config.azure.resourceGroupName)' does not exist and createResourceGroup is false."
    }
    if ($group) {
        $groupObject = $group | ConvertFrom-Json
        if ($groupObject.location -ne $Config.azure.location) {
            throw "Existing resource group location '$($groupObject.location)' does not match '$($Config.azure.location)'."
        }
    }

    $ids = Get-ResourceIds -Config $Config
    Invoke-AzCommand -Arguments @(
        'network', 'vnet', 'subnet', 'show',
        '--resource-group', $Config.network.vnetResourceGroupName,
        '--vnet-name', $Config.network.vnetName,
        '--name', $Config.network.subnetName,
        '--output', 'none', '--only-show-errors'
    ) | Out-Null

    $existingVm = Invoke-AzCommand -Arguments @(
        'vm', 'show',
        '--resource-group', $Config.azure.resourceGroupName,
        '--name', $Config.vm.name,
        '--output', 'none', '--only-show-errors'
    ) -AllowNotFound
    if ($null -ne $existingVm) {
        throw "VM '$($Config.vm.name)' already exists in resource group '$($Config.azure.resourceGroupName)'."
    }

    Invoke-AzCommand -Arguments @(
        'vm', 'image', 'show',
        '--urn', $Config.vm.image,
        '--location', $Config.azure.location,
        '--output', 'none', '--only-show-errors'
    ) | Out-Null

    $skuText = Invoke-AzCommand -Arguments @(
        'vm', 'list-skus',
        '--location', $Config.azure.location,
        '--size', $Config.vm.size,
        '--resource-type', 'virtualMachines',
        '--all', '--output', 'json', '--only-show-errors'
    )
    $skus = @($skuText | ConvertFrom-Json)
    $sku = $skus | Where-Object name -eq $Config.vm.size | Select-Object -First 1
    if (-not $sku) {
        throw "VM size '$($Config.vm.size)' is unavailable in '$($Config.azure.location)'."
    }
    $locationRestriction = @($sku.restrictions) |
        Where-Object { $_.reasonCode -in @('NotAvailableForSubscription', 'QuotaId') }
    if ($locationRestriction) {
        throw "VM size '$($Config.vm.size)' is restricted for this subscription in '$($Config.azure.location)'."
    }

    $vCpuCapability = @($sku.capabilities) |
        Where-Object name -eq 'vCPUs' |
        Select-Object -First 1
    if (-not $vCpuCapability -or -not $sku.family) {
        throw "Unable to determine quota requirements for VM size '$($Config.vm.size)'."
    }
    $requestedCores = [int]$vCpuCapability.value
    $usages = @((Invoke-AzCommand -Arguments @(
        'vm', 'list-usage',
        '--location', $Config.azure.location,
        '--output', 'json', '--only-show-errors'
    )) | ConvertFrom-Json)
    foreach ($quotaName in @($sku.family, 'cores')) {
        $quota = $usages | Where-Object { $_.name.value -eq $quotaName } | Select-Object -First 1
        if ($quota -and ([int]$quota.currentValue + $requestedCores -gt [int]$quota.limit)) {
            throw "Insufficient '$($quota.name.localizedValue)' quota: $($quota.currentValue) used, $requestedCores requested, $($quota.limit) limit."
        }
    }

    foreach ($provider in @(
        'Microsoft.Compute',
        'Microsoft.Network',
        'Microsoft.Authorization',
        'Microsoft.DevTestLab'
    )) {
        $state = Invoke-AzCommand -Arguments @(
            'provider', 'show', '--namespace', $provider,
            '--query', 'registrationState', '--output', 'tsv', '--only-show-errors'
        )
        if ($state.Trim() -ne 'Registered') {
            throw "Azure resource provider '$provider' is not registered."
        }
    }

    $subscriptionScope = "/subscriptions/$($Config.azure.subscriptionId)"
    $targetScope = if ($group) {
        "$subscriptionScope/resourceGroups/$($Config.azure.resourceGroupName)"
    }
    else {
        $subscriptionScope
    }
    $targetActions = @(
        'Microsoft.Compute/virtualMachines/write',
        'Microsoft.Compute/virtualMachines/extensions/write',
        'Microsoft.Compute/virtualMachines/runCommands/write',
        'Microsoft.Authorization/roleAssignments/write',
        'Microsoft.DevTestLab/schedules/write'
    )
    if ($Config.azure.createResourceGroup -and -not $group) {
        $targetActions += 'Microsoft.Resources/subscriptions/resourceGroups/write'
    }
    Assert-AzureActionsAllowed -Scope $targetScope -RequiredActions $targetActions
    Assert-AzureActionsAllowed -Scope $ids.Subnet -RequiredActions @(
        'Microsoft.Network/virtualNetworks/subnets/read',
        'Microsoft.Network/virtualNetworks/subnets/join/action'
    )
}

function New-RuntimePassword {
    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $base = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('/', 'x').Replace('+', 'Y')
    return "A9!$base"
}

function Invoke-AzureDevVmPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject] $Plan,
        [Parameter(Mandatory)][string] $ExpectedPlanHash
    )

    if ($ExpectedPlanHash -cne $Plan.planHash) {
        throw "Approval hash mismatch. Expected '$ExpectedPlanHash'; current plan is '$($Plan.planHash)'. Review the new plan before applying."
    }

    $env:AGENCY_VM_BOOTSTRAP_PASSWORD = New-RuntimePassword
    $completedSteps = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($command in $Plan.commands) {
            if ($command.step -eq 'Install the approved developer toolchain') {
                $artifact = $Plan.artifacts |
                    Where-Object path -eq 'scripts/Install-DeveloperToolchain.ps1' |
                    Select-Object -First 1
                $currentHash = (Get-FileHash -LiteralPath (
                    Join-Path $PSScriptRoot 'Install-DeveloperToolchain.ps1'
                ) -Algorithm SHA256).Hash.ToLowerInvariant()
                if (-not $artifact -or $currentHash -cne $artifact.sha256) {
                    throw 'Install-DeveloperToolchain.ps1 changed after planning. Generate and approve a new plan.'
                }
            }
            $arguments = foreach ($argument in $command.arguments) {
                if ($argument -eq $script:SecretPlaceholder) {
                    $env:AGENCY_VM_BOOTSTRAP_PASSWORD
                }
                else {
                    $argument
                }
            }
            Invoke-AzCommand -Arguments $arguments | Out-Null
            $completedSteps.Add($command.step)
        }
    }
    catch {
        $completed = if ($completedSteps.Count) { $completedSteps -join ', ' } else { 'none' }
        throw "Provisioning stopped after completed steps: $completed. Azure resources may require manual cleanup. $($_.Exception.Message)"
    }
    finally {
        Remove-Item Env:\AGENCY_VM_BOOTSTRAP_PASSWORD -ErrorAction SilentlyContinue
    }

    return $completedSteps
}

Export-ModuleMember -Function @(
    'Assert-Config',
    'New-AzureDevVmPlan',
    'Invoke-AzurePreflight',
    'Invoke-AzureDevVmPlan'
)
