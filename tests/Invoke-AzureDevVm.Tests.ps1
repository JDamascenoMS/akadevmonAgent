$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\AzureDevVm.psm1') -Force
$examplePath = Join-Path $root '.agency\azure-dev-vm.example.json'

function Test-Throws {
    param([scriptblock] $Action)
    try {
        & $Action | Out-Null
        return $false
    }
    catch {
        return $true
    }
}

Describe 'Azure development VM configuration' {
    It 'accepts the checked-in example' {
        $config = Assert-Config -ConfigPath $examplePath
        $config.schemaVersion | Should Be 1
    }

    It 'rejects properties outside the schema' {
        $tempPath = Join-Path $TestDrive 'extra-property.json'
        $config = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json
        $config.azure | Add-Member -NotePropertyName arbitraryCommand -NotePropertyValue 'do-something'
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tempPath
        (Test-Throws { Assert-Config -ConfigPath $tempPath }) | Should Be $true
    }

    It 'rejects non-allowlisted SDK packages' {
        $tempPath = Join-Path $TestDrive 'bad-sdk.json'
        $config = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json
        $config.toolchain.sdkPackages = @('Contoso.Untrusted.Tool')
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tempPath
        (Test-Throws { Assert-Config -ConfigPath $tempPath }) | Should Be $true
    }

    It 'rejects reserved Azure administrator names' {
        $tempPath = Join-Path $TestDrive 'reserved-admin.json'
        $config = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json
        $config.vm.adminUsername = 'admin'
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tempPath
        (Test-Throws { Assert-Config -ConfigPath $tempPath }) | Should Be $true
    }
}

Describe 'Agency plugin package' {
    It 'declares the Copilot agent in the plugin manifest' {
        $manifestPath = Join-Path $root '.github\plugin\plugin.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.name | Should Be 'azure-dev-vm'
        ($manifest.agents -contains 'agents/azure-dev-vm.md') | Should Be $true
        Test-Path -LiteralPath (Join-Path $root $manifest.agents[0]) | Should Be $true
    }

    It 'declares the Claude agent in the Claude plugin manifest' {
        $manifestPath = Join-Path $root '.claude-plugin\plugin.json'
        Test-Path -LiteralPath $manifestPath | Should Be $true
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.name | Should Be 'azure-dev-vm'
        Test-Path -LiteralPath (Join-Path $root $manifest.agents[0]) | Should Be $true
    }

    It 'points both engine manifests at the same agent definition' {
        $copilotManifest = Get-Content -LiteralPath (
            Join-Path $root '.github\plugin\plugin.json'
        ) -Raw | ConvertFrom-Json
        $claudeManifest = Get-Content -LiteralPath (
            Join-Path $root '.claude-plugin\plugin.json'
        ) -Raw | ConvertFrom-Json
        $claudeManifest.name | Should Be $copilotManifest.name
        $claudeManifest.version | Should Be $copilotManifest.version
        $claudeAgent = (Resolve-Path -LiteralPath (Join-Path $root $claudeManifest.agents[0])).Path
        $copilotAgent = (Resolve-Path -LiteralPath (Join-Path $root $copilotManifest.agents[0])).Path
        $claudeAgent | Should Be $copilotAgent
    }

    It 'contributes the plugin through the marketplace catalog' {
        $catalog = Get-Content -LiteralPath (
            Join-Path $root '.claude-plugin\marketplace.json'
        ) -Raw | ConvertFrom-Json
        $catalog.name | Should Be 'azure-dev-vm-marketplace'
        $catalog.plugins[0].name | Should Be 'azure-dev-vm'
        $catalog.plugins[0].source | Should Be './'
    }

    It 'resolves bundled scripts through the plugin root' {
        $instructions = Get-Content -LiteralPath (Join-Path $root 'agents\azure-dev-vm.md') -Raw
        $instructions | Should Match 'COPILOT_PLUGIN_ROOT'
    }

    It 'keeps repository and plugin agent definitions identical' {
        $repositoryAgent = Get-Content -LiteralPath (
            Join-Path $root '.github\agents\azure-dev-vm.md'
        ) -Raw
        $pluginAgent = Get-Content -LiteralPath (
            Join-Path $root 'agents\azure-dev-vm.md'
        ) -Raw
        $pluginAgent.Replace("`r`n", "`n") | Should Be $repositoryAgent.Replace("`r`n", "`n")
    }
}

Describe 'Azure development VM plan' {
    BeforeEach {
        $config = Assert-Config -ConfigPath $examplePath
        $plan = New-AzureDevVmPlan -Config $config
    }

    It 'is deterministic' {
        $secondPlan = New-AzureDevVmPlan -Config $config
        $plan.planHash | Should Be $secondPlan.planHash
    }

    It 'binds VM-side script content into the approval hash' {
        $plan.artifacts.Count | Should Be 1
        $plan.artifacts[0].path | Should Be 'scripts/Install-DeveloperToolchain.ps1'
        $plan.artifacts[0].sha256 | Should Match '^[0-9a-f]{64}$'
    }

    It 'creates no public IP or NSG' {
        $vmCommand = $plan.commands | Where-Object step -eq 'Create private Windows VM'
        $publicIpIndex = [Array]::IndexOf($vmCommand.arguments, '--public-ip-address')
        $nsgIndex = [Array]::IndexOf($vmCommand.arguments, '--nsg')
        $vmCommand.arguments[$publicIpIndex + 1] | Should Be ''
        $vmCommand.arguments[$nsgIndex + 1] | Should Be ''
        ($vmCommand.arguments -contains '--open-ports') | Should Be $false
    }

    It 'redacts the generated bootstrap password' {
        $vmCommand = $plan.commands | Where-Object step -eq 'Create private Windows VM'
        $vmCommand.command | Should Match '\$env:AGENCY_VM_BOOTSTRAP_PASSWORD'
        $vmCommand.command | Should Not Match 'A9!'
    }

    It 'binds apply to the reviewed plan hash before Azure execution' {
        (Test-Throws {
            Invoke-AzureDevVmPlan -Plan $plan -ExpectedPlanHash ('0' * 64)
        }) | Should Be $true
    }

    It 'escapes display-only tag values without changing argument boundaries' {
        $config.azure.tags.purpose = "team's vm"
        $taggedPlan = New-AzureDevVmPlan -Config $config
        $groupCommand = $taggedPlan.commands | Where-Object step -eq 'Create or update resource group'
        $groupCommand.command | Should Match "'purpose=team''s vm'"
        ($groupCommand.arguments -contains "purpose=team's vm") | Should Be $true
    }

    It 'uses managed Run Command with a four-hour timeout' {
        $installCommand = $plan.commands | Where-Object step -eq 'Install the approved developer toolchain'
        ($installCommand.arguments -contains 'create') | Should Be $true
        ($installCommand.arguments -contains '--timeout-in-seconds') | Should Be $true
        ($installCommand.arguments -contains '14400') | Should Be $true
    }
}
