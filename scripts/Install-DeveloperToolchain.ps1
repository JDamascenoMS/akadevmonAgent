param(
    [string] $SdkPackages,
    [Parameter(Mandatory)][string] $VisualStudioEdition,
    [Parameter(Mandatory)][string] $VisualStudioWorkloads,
    [string] $VisualStudioComponents,
    [Parameter(Mandatory)][string] $IncludeRecommended,
    [Parameter(Mandatory)][string] $AdminUsername
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$allowedSdkPackages = @(
    'Microsoft.DotNet.SDK.8',
    'Microsoft.DotNet.SDK.9',
    'Microsoft.DotNet.SDK.10'
)
$allowedEditions = @('Enterprise', 'Professional', 'Community')
$allowedWorkloads = @(
    'Microsoft.VisualStudio.Workload.ManagedDesktop',
    'Microsoft.VisualStudio.Workload.NetWeb',
    'Microsoft.VisualStudio.Workload.Azure',
    'Microsoft.VisualStudio.Workload.NativeDesktop',
    'Microsoft.VisualStudio.Workload.Universal',
    'Microsoft.VisualStudio.Workload.Data'
)
$allowedComponents = @(
    'Microsoft.VisualStudio.Component.Git',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    'Microsoft.VisualStudio.Component.Windows11SDK.26100',
    'Microsoft.VisualStudio.ComponentGroup.Azure.Prerequisites'
)

function ConvertFrom-List {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }
    return @($Value.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries))
}

function Assert-Allowlisted {
    param(
        [string[]] $Values,
        [string[]] $Allowlist,
        [string] $Setting
    )
    foreach ($value in $Values) {
        if ($value -notin $Allowlist) {
            throw "Unsupported $Setting value '$value'."
        }
    }
}

$sdkList = ConvertFrom-List $SdkPackages
$workloadList = ConvertFrom-List $VisualStudioWorkloads
$componentList = ConvertFrom-List $VisualStudioComponents
$includeRecommendedValue = $false
if (-not [bool]::TryParse($IncludeRecommended, [ref]$includeRecommendedValue)) {
    throw "IncludeRecommended must be 'True' or 'False', not '$IncludeRecommended'."
}

Assert-Allowlisted -Values $sdkList -Allowlist $allowedSdkPackages -Setting 'SDK package'
Assert-Allowlisted -Values $workloadList -Allowlist $allowedWorkloads -Setting 'Visual Studio workload'
Assert-Allowlisted -Values $componentList -Allowlist $allowedComponents -Setting 'Visual Studio component'
if ($VisualStudioEdition -notin $allowedEditions) {
    throw "Unsupported Visual Studio edition '$VisualStudioEdition'."
}
if ($workloadList.Count -eq 0) {
    throw 'At least one Visual Studio workload is required.'
}

$workDirectory = Join-Path $env:ProgramData 'Agency\AzureDevVm'
New-Item -ItemType Directory -Force -Path $workDirectory | Out-Null

$dotnetInstallPath = Join-Path $workDirectory 'dotnet-install.ps1'
Invoke-WebRequest -UseBasicParsing -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $dotnetInstallPath
$sdkChannels = @{
    'Microsoft.DotNet.SDK.8' = '8.0'
    'Microsoft.DotNet.SDK.9' = '9.0'
    'Microsoft.DotNet.SDK.10' = '10.0'
}
foreach ($package in $sdkList) {
    & $dotnetInstallPath -Channel $sdkChannels[$package] -InstallDir "$env:ProgramFiles\dotnet" -NoPath
    if (-not $?) {
        throw "dotnet-install failed for '$package'."
    }
}
[Environment]::SetEnvironmentVariable(
    'Path',
    "$env:ProgramFiles\dotnet;" + [Environment]::GetEnvironmentVariable('Path', 'Machine'),
    'Machine'
)

$editionSlug = $VisualStudioEdition.ToLowerInvariant()
$bootstrapperPath = Join-Path $workDirectory "vs_$editionSlug.exe"
Invoke-WebRequest -UseBasicParsing -Uri "https://aka.ms/vs/17/release/vs_$editionSlug.exe" -OutFile $bootstrapperPath
$installerArguments = @('--wait', '--quiet', '--norestart')
foreach ($workload in $workloadList) {
    $installerArguments += @('--add', $workload)
}
foreach ($component in $componentList) {
    $installerArguments += @('--add', $component)
}
if ($includeRecommendedValue) {
    $installerArguments += '--includeRecommended'
}
$installation = Start-Process -FilePath $bootstrapperPath -ArgumentList $installerArguments -Wait -PassThru
if ($installation.ExitCode -notin @(0, 3010)) {
    throw "Visual Studio bootstrapper failed for edition '$VisualStudioEdition' (exit $($installation.ExitCode))."
}

$localUser = Get-LocalUser -Name $AdminUsername -ErrorAction Stop
if ($localUser.Enabled) {
    Disable-LocalUser -Name $AdminUsername
}

Write-Output 'Developer toolchain installation succeeded and the bootstrap local account was disabled.'
