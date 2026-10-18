function Get-TurnstileAccessReview {
    <#
    .SYNOPSIS
        Who has what, and what needs looking at.
    .DESCRIPTION
        Lists every group membership with where it came from (their job, an approval, granted
        by hand, a service account), and flags the risks:
          High    privileged access with no current approval; an approval the audit log doesn't
                  back up; leavers still in groups; an audit log that fails its check
          Medium  access granted by hand; staff missing from the HR export; requests waiting
                  too long for a decision; service accounts in privileged groups; accounts
                  switched off by hand but still in groups
          Low     approvals and contracts ending soon; accounts with no employee ID
        Changes nothing. Give -HrPath to also check against today's HR export.
    .EXAMPLE
        Get-TurnstileAccessReview -DirectoryPath .\demo-output\directory.json | Show-TurnstileAccessReview
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $DirectoryPath,
        [string] $HrPath,
        [string] $PolicyPath = $script:DefaultPolicy,
        [string] $ApprovalPath,
        [string] $AuditPath,
        [datetime] $Today = (Get-Date).Date
    )
    $Today = $Today.Date
    $policy = Read-TurnstilePolicy -Path $PolicyPath
    $directory = Open-TurnstileDirectory -Path $DirectoryPath
    $paths = Get-TurnstilePaths -Directory $directory -ApprovalPath $ApprovalPath -AuditPath $AuditPath
    $store = Open-TurnstileApprovals -Path $paths.Approvals
    $view = Get-TurnstileApprovalView -Store $store -AuditPath $paths.Audit
    $managedGroups = Get-TurnstileManagedGroup $policy
    $soon = $Today.AddDays([int] $policy.review.soonDays)
    $records = @{}
    if ($HrPath) { foreach ($r in (Import-TurnstileHrFeed -Path $HrPath -Policy $policy).Records) { $records[$r.EmployeeId] = $r } }

    $findings = [Collections.Generic.List[object]]::new()
    $flag = { param($severity, $category, $user, $detail)
        $findings.Add([pscustomobject]@{ Severity = $severity; Category = $category; Username = $user; Detail = $detail }) }
    $entries = [Collections.Generic.List[object]]::new()
    $users = @(Get-TurnstileDirectoryUser $directory)
    $names = @{}; foreach ($u in $users) { $names[$u.username] = $u.displayName }

    if ($view.AuditProblem) { & $flag 'High' 'Audit log' '' "The audit log fails its check: $($view.AuditProblem) No approval can be trusted until this is explained." }

    foreach ($u in $users | Sort-Object username) {
        $managed = [bool] $u.employeeId
        $groups = @($u.groups)
        $record = if ($managed) { $records[$u.employeeId] } else { $null }
        $entitled = if ($record) { Get-TurnstileEntitlement -Policy $policy -Record $record } else { $null }

        if (-not $managed) {
            & $flag 'Low' 'No employee ID' $u.username "$($u.username) ($($u['description'])) isn't linked to a person, so Turnstile never manages it. Check it still has an owner and is still needed."
        } elseif (-not $u.enabled -and $groups.Count) {
            $startingSoon = $record -and (Get-TurnstilePhase $record $Today $policy.prestartDays) -eq 'prestart'
            if ($u.disabledOn) {
                & $flag 'High' 'Disabled with access' $u.username "$($u.username) was disabled on $($u.disabledOn) but is still in $($groups.Count) group(s): $($groups -join ', ')."
            } elseif (-not $startingSoon) {
                # New starters are set up switched off with their groups, so they're not flagged.
                & $flag 'Medium' 'Disabled with access' $u.username "$($u.username) is switched off (not by Turnstile) but still in $($groups.Count) group(s): $($groups -join ', '). Fine for a new starter; otherwise check why."
            }
        }
        if ($managed -and $u.enabled -and $HrPath -and -not $record) {
            & $flag 'Medium' 'Not in HR export' $u.username "$($u.username) is enabled but isn't in the HR export."
        }
        if ($managed -and $u.enabled -and $u['accountExpires']) {
            $ends = ConvertTo-TurnstileDate $u.accountExpires
            if ($ends -and $ends -ge $Today -and $ends -le $soon) {
                & $flag 'Low' 'Ending soon' $u.username "$($u.username)'s account expires on $($u.accountExpires) (contract or notice ends)."
            }
        }

        foreach ($g in $groups | Sort-Object) {
            $privileged = Test-TurnstilePrivileged -Policy $policy -Group $g
            $approvalId = ''; $expires = ''
            if (-not $managed) {
                $source = 'Service account'
                if ($privileged) { & $flag 'Medium' 'Service account with privileges' $u.username "$($u.username) is in $g. Accounts like this are a favourite target: confirm it needs to be." }
            } elseif (-not $u.enabled) {
                $source = 'Disabled account'
            } elseif ($privileged) {
                $st = Get-TurnstileApprovalState -View $view -EmployeeId $u.employeeId -Group $g -Today $Today -Title $u.title
                switch ($st.State) {
                    'Valid' {
                        $source = "Approved ($($st.Request.id))"; $approvalId = $st.Request.id; $expires = $st.Request.expiresOn
                        if ((ConvertTo-TurnstileDate $expires) -le $soon) { & $flag 'Low' 'Approval ending soon' $u.username "$($u.username)'s approval for $g ($($st.Request.id)) ends on $expires." }
                    }
                    'Unbacked' {
                        $source = 'Approval not in audit log'; $approvalId = $st.Request.id
                        & $flag 'High' 'Approval not in audit log' $u.username "$($st.Request.id) says $($u.username) is approved for $g, but the audit log has no matching approval. Someone may have edited approvals.json."
                    }
                    default {
                        $source = if ($st.State -eq 'Pending') { "Waiting for approval ($($st.Request.id))" } else { 'No approval' }
                        & $flag 'High' 'Privileged without approval' $u.username "$($u.username) is in $g (privileged) with no current approval$(if ($st.State -eq 'Pending') { "; $($st.Request.id) is waiting for a decision" })."
                    }
                }
            } elseif ($managedGroups -contains $g) {
                $source = if (-not $record) { 'Policy group' } elseif ($entitled -contains $g) { 'Their job' } else { 'Not part of their job' }
            } else {
                $source = 'Granted by hand'
                & $flag 'Medium' 'Granted by hand' $u.username "$($u.username) is in $g, which no policy gives them. Was it meant to be permanent?"
            }
            $entries.Add([pscustomobject]@{
                Manager = $(if ($u['manager']) { "$($names[$u.manager]) ($($u.manager))" } else { '' })
                Username = $u.username; Name = $u.displayName; Title = $u['title']; Department = $u['department']; Enabled = [bool] $u.enabled
                Group = $g; Privileged = $privileged; Source = $source; ApprovalId = $approvalId; ApprovalExpires = $expires; Decision = ''
            })
        }
    }

    foreach ($r in $store.State.requests | Where-Object status -eq 'Pending') {
        $age = ($Today - (ConvertTo-TurnstileDate $r.requestedOn)).Days
        if ($age -ge [int] $policy.review.pendingDays) {
            & $flag 'Medium' 'Waiting too long' $r.username "$($r.id) ($($r.group) for $($r.username)) has waited $age days for a decision."
        }
    }

    $order = @{ High = 0; Medium = 1; Low = 2 }
    $sorted = @($findings | Sort-Object { $order[$_.Severity] }, Category, Username)
    [pscustomobject]@{
        Today    = $Today
        Findings = $sorted
        Entries  = @($entries | Sort-Object Manager, Username, Group)
        Summary  = [ordered]@{
            Accounts    = $users.Count
            People      = @($users | Where-Object { $_.employeeId -and $_.enabled }).Count
            Memberships = $entries.Count
            Privileged  = @($entries | Where-Object Privileged).Count
            High        = @($sorted | Where-Object Severity -eq 'High').Count
            Medium      = @($sorted | Where-Object Severity -eq 'Medium').Count
            Low         = @($sorted | Where-Object Severity -eq 'Low').Count
        }
    }
}

function Show-TurnstileAccessReview {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Show- commands are for people at a console.')]
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)] $Review)
    process {
        $s = $Review.Summary
        Write-Host ("Access review for {0}: {1} people, {2} accounts, {3} group memberships ({4} privileged)" -f
            (Format-TurnstileDate $Review.Today -Long), $s.People, $s.Accounts, $s.Memberships, $s.Privileged)
        Write-Host ("  {0} high, {1} medium, {2} low" -f $s.High, $s.Medium, $s.Low)
        $colours = @{ High = 'Red'; Medium = 'DarkYellow'; Low = 'DarkGray' }
        foreach ($f in $Review.Findings) {
            Write-Host ("  {0,-6} {1}: {2}" -f $f.Severity.ToUpper(), $f.Category, $f.Detail) -ForegroundColor $colours[$f.Severity]
        }
    }
}

function Export-TurnstileAccessReview {
    <#
    .SYNOPSIS
        Save a review as two CSV files for managers: the findings, and every membership with a
        blank Decision column to fill in (Keep or Remove).
    .OUTPUTS
        The paths of the two files.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)] $Review, [Parameter(Mandatory)][string] $Folder)
    process {
        if (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Path $Folder | Out-Null }
        $day = Format-TurnstileDate $Review.Today
        $findings = Join-Path $Folder "access-review-$day-findings.csv"
        $access = Join-Path $Folder "access-review-$day.csv"
        $Review.Findings | ForEach-Object { ConvertTo-TurnstileSafeCsvRow $_ } | Export-Csv -LiteralPath $findings -NoTypeInformation -Encoding utf8BOM
        $Review.Entries | ForEach-Object { ConvertTo-TurnstileSafeCsvRow $_ } | Export-Csv -LiteralPath $access -NoTypeInformation -Encoding utf8BOM
        $findings, $access
    }
}

function ConvertTo-TurnstileSafeCsvRow {
    # A cell starting with = + - @ is run as a formula when the CSV is opened in Excel
    # ("CSV injection"). Directory data can contain anything, so such cells get a leading '.
    param($Row)
    $safe = [ordered]@{}
    foreach ($p in $Row.PSObject.Properties) {
        $v = $p.Value
        if ($v -is [string] -and $v -match '^[=+\-@\t\r]') { $v = "'$v" }
        $safe[$p.Name] = $v
    }
    [pscustomobject] $safe
}
