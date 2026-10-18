#Requires -Version 7.4
# Runs the Pester tests. Needs Pester 5.5 or newer:
#   Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
param([string] $Path = (Join-Path $PSScriptRoot 'tests'), [string] $Output = 'Normal')
if (-not (Get-Module Pester -ListAvailable | Where-Object Version -ge ([version] '5.5'))) {
    Write-Host 'These tests need Pester 5.5 or newer. Windows comes with Pester 3.4, which is too old.' -ForegroundColor Yellow
    Write-Host 'Install it once (answer A if asked about an untrusted repository), then run this again:' -ForegroundColor Yellow
    Write-Host '    Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.5'
    exit 1
}
Import-Module Pester -MinimumVersion 5.5 -ErrorAction Stop
$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.Exit = $true
$config.Output.Verbosity = $Output
$config.TestResult.Enabled = [bool] $env:CI
$config.TestResult.OutputPath = Join-Path $PSScriptRoot 'test-results.xml'
Invoke-Pester -Configuration $config
