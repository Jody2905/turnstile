#Requires -Version 7.4
# Runs the Pester tests. Needs Pester 5.5 or newer:
#   Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
param([string] $Path = (Join-Path $PSScriptRoot 'tests'), [string] $Output = 'Normal')
Import-Module Pester -MinimumVersion 5.5 -ErrorAction Stop
$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.Exit = $true
$config.Output.Verbosity = $Output
$config.TestResult.Enabled = [bool] $env:CI
$config.TestResult.OutputPath = Join-Path $PSScriptRoot 'test-results.xml'
Invoke-Pester -Configuration $config
