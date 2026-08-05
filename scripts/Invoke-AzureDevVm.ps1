[CmdletBinding(DefaultParameterSetName = 'Plan')]
param(
    [Parameter(Mandatory)]
    [string] $ConfigPath,

    [Parameter(ParameterSetName = 'Plan')]
    [switch] $Plan,

    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [switch] $Apply,

    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string] $ExpectedPlanHash,

    [Parameter(ParameterSetName = 'Plan')]
    [switch] $Offline,

    [ValidateSet('Text', 'Json')]
    [string] $OutputFormat = 'Text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AzureDevVm.psm1') -Force

$config = Assert-Config -ConfigPath $ConfigPath
if (-not $Offline) {
    Invoke-AzurePreflight -Config $config
}
$generatedPlan = New-AzureDevVmPlan -Config $config

if ($Apply) {
    $completed = Invoke-AzureDevVmPlan -Plan $generatedPlan -ExpectedPlanHash $ExpectedPlanHash
    [pscustomobject]@{
        status         = 'Succeeded'
        resourceId     = $generatedPlan.resourceId
        planHash       = $generatedPlan.planHash
        completedSteps = $completed
    } | ConvertTo-Json -Depth 5
    exit 0
}

if ($OutputFormat -eq 'Json') {
    $generatedPlan | ConvertTo-Json -Depth 10
    exit 0
}

Write-Output "Plan hash: $($generatedPlan.planHash)"
Write-Output "Target: $($generatedPlan.resourceId)"
if ($Offline) {
    Write-Warning 'Offline plan: Azure authentication, resource availability, permissions, networking, and collisions were not checked.'
}
Write-Output ''
foreach ($command in $generatedPlan.commands) {
    Write-Output "[$($command.step)]"
    Write-Output $command.command
    Write-Output ''
}
Write-Output 'No Azure resources were changed. Apply requires this exact plan hash.'
