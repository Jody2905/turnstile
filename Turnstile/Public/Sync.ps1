$script:DefaultPolicy = Join-Path $PSScriptRoot '../../config/policy.json'

function Get-TurnstilePlan {
    <#
    .SYNOPSIS
        Show what would change, without changing anything.
    .EXAMPLE
        Get-TurnstilePlan -HrPath .\data\hr\2026-10-19.csv -DirectoryPath .\directory.json -Today 2026-10-19 | Show-TurnstilePlan
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $HrPath,
        [Parameter(Mandatory)][string] $DirectoryPath,
        [string] $PolicyPath = $script:DefaultPolicy,
        [datetime] $Today = (Get-Date).Date
    )
    $policy = Read-TurnstilePolicy -Path $PolicyPath
    $directory = Open-TurnstileDirectory -Path $DirectoryPath
    $feed = Import-TurnstileHrFeed -Path $HrPath -Policy $policy
    New-TurnstilePlan -Policy $policy -Directory $directory -Feed $feed -Today $Today
}

function Invoke-TurnstileSync {
    <#
    .SYNOPSIS
        Bring the directory in line with today's HR export: joiners, movers and leavers.
    .DESCRIPTION
        Works out the plan, then carries out every ready action and writes each one to the
        audit log. Supports -WhatIf (show, change nothing) and -Confirm (ask before each one).

        It refuses to run when the export looks broken: too many staff missing from it, or
        too many accounts would be disabled at once. -Force with a -Reason overrides that,
        and the reason goes in the audit log.

        Privileged groups are never added automatically; those actions are listed as
        needing approval.

        Each new account gets a random temporary password that must be changed at first
        sign-in. It's written once, to a note in -CredentialPath for the manager, and
        never to the audit log or the directory file.
    .EXAMPLE
        Invoke-TurnstileSync -HrPath .\data\hr\2026-10-19.csv -DirectoryPath .\directory.json -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string] $HrPath,
        [Parameter(Mandatory)][string] $DirectoryPath,
        [string] $PolicyPath = $script:DefaultPolicy,
        [string] $AuditPath,
        [string] $CredentialPath,
        [datetime] $Today = (Get-Date).Date,
        [switch] $Force,
        [string] $Reason
    )
    $policy = Read-TurnstilePolicy -Path $PolicyPath
    $directory = Open-TurnstileDirectory -Path $DirectoryPath
    $folder = Split-Path -Parent $directory.Path
    if (-not $AuditPath) { $AuditPath = Join-Path $folder 'audit.log' }
    if (-not $CredentialPath) { $CredentialPath = Join-Path $folder 'new-starter-notes' }
    $feed = Import-TurnstileHrFeed -Path $HrPath -Policy $policy
    $plan = New-TurnstilePlan -Policy $policy -Directory $directory -Feed $feed -Today $Today

    $dryRun = [bool] $WhatIfPreference
    $runId = 'run-{0}-{1}' -f (Get-Date -Format 'yyyyMMddHHmmss'), (Get-Random -Maximum 99999).ToString('00000')
    $audit = { param($event, $target, $detail, $data = @{})
        if (-not $dryRun) { Add-TurnstileAuditEntry -Path $AuditPath -RunId $runId -Event $event -Target $target -Detail $detail -Data $data } }
    $result = [pscustomobject]@{
        RunId = $runId; Plan = $plan; Applied = 0; Failed = 0; Skipped = 0; Refused = $false; DryRun = $dryRun
        Errors = [Collections.Generic.List[string]]::new(); NewStarterNotes = [Collections.Generic.List[string]]::new()
    }

    & $audit 'RunStarted' '' "HR export $(Split-Path -Leaf $HrPath) for $(Format-TurnstileDate $plan.Today)" @{
        hrRows = $plan.HrRows; ready = @($plan.Actions | Where-Object Status -eq 'Ready').Count; issues = $plan.Issues.Count }
    if ($plan.Blocked) {
        if (-not $Force) {
            $result.Refused = $true
            & $audit 'RunRefused' '' $plan.BlockedReason
            return $result
        }
        if ([string]::IsNullOrWhiteSpace($Reason)) { throw '-Force needs a -Reason, which is written to the audit log.' }
        & $audit 'SafetyOverride' '' "$($plan.BlockedReason) Overridden: $Reason" @{ user = [Environment]::UserName }
    }

    $failedUsers = [Collections.Generic.HashSet[string]]::new()
    try {
        foreach ($action in $plan.Actions) {
            if ($action.Status -ne 'Ready') { continue }
            if ($failedUsers.Contains($action.Username)) { $result.Skipped++; continue }
            if (-not $PSCmdlet.ShouldProcess($action.Username, $action.Detail)) { continue }
            $password = if ($action.Kind -eq 'Create') { New-TurnstilePassword } else { $null }
            try {
                Invoke-TurnstileDirectoryAction -Directory $directory -Action $action -Today $plan.Today -Password $password
            } catch {
                [void] $failedUsers.Add($action.Username)
                $result.Failed++
                $result.Errors.Add("$($action.Username): $($action.Detail): $($_.Exception.Message)")
                & $audit 'Failed' $action.Username "$($action.Detail): $($_.Exception.Message)"
                continue
            }
            $result.Applied++
            $data = @{}
            if ($action.Kind -eq 'Create') {
                $data = @{ employeeId = $action.EmployeeId; ou = $action.Data.ou; enabled = $action.Data.enabled }
                $result.NewStarterNotes.Add((Write-TurnstileStarterNote -Folder $CredentialPath -Action $action -Password $password -Policy $policy -Today $plan.Today))
                $detail = "$($action.Detail). Temporary password issued (not recorded here); must be changed at first sign-in."
            } else {
                $detail = $action.Detail
                if ($action.Kind -eq 'Update') { foreach ($k in $action.Data.Keys) { $data[$k] = @{ old = $action.Data[$k].old; new = $action.Data[$k].new } } }
                elseif ($action.Kind -in 'AddGroup', 'RemoveGroup') { $data = @{ group = $action.Data.group } }
                elseif ($action.Kind -eq 'Move') { $data = @{ from = $action.Data.from; to = $action.Data.to } }
            }
            & $audit $action.Kind $action.Username $detail $data
        }
    } finally {
        if (-not $dryRun -and $result.Applied -gt 0) { Save-TurnstileDirectory -Directory $directory }
    }
    & $audit 'RunCompleted' '' "Applied $($result.Applied), failed $($result.Failed), skipped $($result.Skipped); $($plan.Summary.NeedsApproval) waiting for approval" @{
        applied = $result.Applied; failed = $result.Failed; skipped = $result.Skipped; needsApproval = $plan.Summary.NeedsApproval }
    $result
}

function Write-TurnstileStarterNote {
    # The manager's note for a new starter: the only place the temporary password is written.
    param($Folder, $Action, $Password, $Policy, [datetime] $Today)
    if (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Path $Folder | Out-Null }
    $path = Join-Path $Folder "$($Action.Username).txt"
    $starts = if ($Action.Data.enabled) { 'The account is ready to use now.' } else { 'The account stays switched off until their first day.' }
    @"
Welcome to $($Policy.organisation): sign-in details for $($Action.Data.displayName)

Username:            $($Action.Username)
Email:               $($Action.Data.mail)
Temporary password:  $Password

$starts
They'll be asked to choose their own password the first time they sign in.

Give these details to $($Action.Data.displayName) in person, then delete this file.
Created by Turnstile on $(Format-TurnstileDate $Today).
"@ | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    $path
}
