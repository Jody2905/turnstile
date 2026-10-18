function Show-TurnstilePlan {
    <#
    .SYNOPSIS
        Print a plan (from Get-TurnstilePlan) or a run (from Invoke-TurnstileSync) in colour.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Show- commands are for people at a console.')]
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)] $InputObject)
    process {
        $plan = if ($InputObject.PSObject.Properties['Plan']) { $InputObject.Plan } else { $InputObject }
        $symbols = @{ Confirm = '?'; Create = '+'; Enable = '+'; Update = '~'; Move = '>'; AddGroup = '+'; RemoveGroup = '-'; Disable = 'x'; Delete = 'x' }
        $colours = @{ Confirm = 'Magenta'; Create = 'Green'; Enable = 'Green'; Update = 'Cyan'; Move = 'Cyan'; AddGroup = 'Green'; RemoveGroup = 'Yellow'; Disable = 'Red'; Delete = 'Red' }

        Write-Host ("HR export: {0} ({1} rows)   Day: {2}" -f (Split-Path -Leaf $plan.HrPath), $plan.HrRows, (Format-TurnstileDate $plan.Today -Long))
        if ($plan.Blocked) {
            Write-Host "  STOPPED: $($plan.BlockedReason)" -ForegroundColor Red
            Write-Host '  Nothing will be changed. Fix the export, or re-run with -Force -Reason "..." if this is really intended.' -ForegroundColor Red
        }
        $byUser = $plan.Actions | Group-Object Username
        if (-not $plan.Actions) { Write-Host '  Nothing to do: the directory already matches HR.' -ForegroundColor DarkGray }
        foreach ($group in $byUser) {
            $first = $group.Group[0]
            Write-Host ("  {0} ({1}, {2})" -f $group.Name, $first.Name, $first.EmployeeId)
            foreach ($a in $group.Group) {
                if ($a.Status -eq 'NeedsApproval') {
                    Write-Host "      ? $($a.Detail)" -ForegroundColor Magenta
                } else {
                    Write-Host "      $($symbols[$a.Kind]) $($a.Detail)" -ForegroundColor $colours[$a.Kind]
                }
            }
        }
        foreach ($i in $plan.Issues) {
            $where = if ($i.Line) { "line $($i.Line)" } else { $i.EmployeeId }
            $colour = if ($i.Severity -eq 'Error') { 'Red' } else { 'DarkYellow' }
            Write-Host "  ! $($i.Severity) ($where): $($i.Message)" -ForegroundColor $colour
        }
        if ($InputObject.PSObject.Properties['Applied']) {
            $r = $InputObject
            if ($r.DryRun) { Write-Host '  -WhatIf: nothing was changed.' -ForegroundColor DarkGray }
            elseif ($r.Refused) { Write-Host '  Run refused; recorded in the audit log.' -ForegroundColor Red }
            else {
                Write-Host ("  Done: {0} applied, {1} failed, {2} skipped, {3} waiting for approval." -f $r.Applied, $r.Failed, $r.Skipped, $plan.Summary.NeedsApproval)
                foreach ($e in $r.Errors) { Write-Host "  FAILED $e" -ForegroundColor Red }
            }
        }
    }
}
