# Working out what should change: compare what HR says with what the directory holds.
#
# For each person in the HR export, Turnstile works out the account they should have today
# (enabled or not, which OU, which groups, name, title, manager...), compares it with the
# account they do have, and lists the differences as actions. Nothing is changed here.
#
# Where someone is in their working life on a given day:
#   too early     start date more than prestartDays away: nothing yet
#   prestart      starting within prestartDays: account created, but disabled
#   active        started and not left: enabled, with the access their job gives
#   leaver        the day after their end date: disabled, all groups removed, moved to the
#                 Disabled OU; deleted leaverRetentionDays later

$script:AttributeOrder = 'givenName', 'surname', 'displayName', 'title', 'department', 'office', 'manager', 'accountExpires', 'description'

function Get-TurnstilePhase {
    param([Parameter(Mandatory)] $Record, [Parameter(Mandatory)][datetime] $Today, [Parameter(Mandatory)][int] $PrestartDays)
    if ($Record.EndDate -and $Today -gt $Record.EndDate) { return 'leaver' }
    if ($Today -ge $Record.StartDate) { return 'active' }
    if (($Record.StartDate - $Today).Days -le $PrestartDays) { return 'prestart' }
    'early'
}

function New-TurnstilePlan {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Makes a new value; changes nothing.')]
    param(
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] $Directory,
        [Parameter(Mandatory)] $Feed,
        [Parameter(Mandatory)][datetime] $Today,
        $Approvals   # from Get-TurnstileApprovalView; none means no approvals on record
    )
    $Today = $Today.Date
    $actions = [Collections.Generic.List[object]]::new()
    $issues = [Collections.Generic.List[object]]::new()
    foreach ($i in $Feed.Issues) { $issues.Add($i) }
    $note = { param($severity, $id, $message) $issues.Add([pscustomobject]@{ Severity = $severity; Line = $null; EmployeeId = $id; Message = $message }) }
    $add = { param($kind, $user, $record, $detail, $data, $status = 'Ready')
        $actions.Add([pscustomobject]@{
            Kind = $kind; Username = $user; EmployeeId = $record.EmployeeId
            Name = $(if ($record.PSObject.Properties['FirstName']) { "$(if ($record.PreferredName) { $record.PreferredName } else { $record.FirstName }) $($record.LastName)" } else { $record.displayName })
            Detail = $detail; Data = $data; Status = $status
        }) }

    # The policy and the directory must agree about which groups exist.
    $directoryGroups = Get-TurnstileDirectoryGroupName $Directory
    $managedGroups = Get-TurnstileManagedGroup $Policy
    $unknown = $managedGroups | Where-Object { $directoryGroups -notcontains $_ }
    if ($unknown) { throw "The policy hands out groups the directory doesn't have: $($unknown -join ', ')." }

    $allUsers = @(Get-TurnstileDirectoryUser $Directory)
    $managed = @($allUsers | Where-Object { $_.employeeId })
    $byEmployee = @{}
    foreach ($u in $managed) { $byEmployee[$u.employeeId] = $u }
    $records = @($Feed.Records)
    $byId = @{}
    foreach ($r in $records) { $byId[$r.EmployeeId] = $r }
    $rejected = [Collections.Generic.HashSet[string]]::new([string[]] @($Feed.RejectedIds))

    # Usernames for joiners are worked out first, so managers created today can be referred to.
    $taken = [Collections.Generic.List[string]]::new()
    foreach ($u in $allUsers) { $taken.Add($u.username) }
    $newNames = @{}
    foreach ($r in $records) {
        if ($byEmployee.ContainsKey($r.EmployeeId)) { continue }
        $phase = Get-TurnstilePhase -Record $r -Today $Today -PrestartDays $Policy.prestartDays
        if ($phase -notin 'prestart', 'active') { continue }
        $first = if ($r.PreferredName) { $r.PreferredName } else { $r.FirstName }
        $name = New-TurnstileUsername -First $first -Last $r.LastName -Taken $taken -MaxLength $Policy.usernameMaxLength
        $taken.Add($name)
        $newNames[$r.EmployeeId] = $name
    }
    $usernameFor = { param($employeeId)
        if (-not $employeeId) { return $null }
        if ($byEmployee.ContainsKey($employeeId)) { return $byEmployee[$employeeId].username }
        $newNames[$employeeId] }

    # Joiners whose manager is also joining today are created after their manager.
    $ordered = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.List[object]]::new([object[]] @($records | Where-Object { $newNames.ContainsKey($_.EmployeeId) }))
    while ($pending.Count) {
        $pendingIds = @($pending | ForEach-Object { $_.EmployeeId })
        $ready = @($pending | Where-Object { -not ($_.ManagerId -and ($pendingIds -contains $_.ManagerId)) })
        if (-not $ready) { $ready = @($pending[0]) }   # a loop in the data: just carry on
        foreach ($r in $ready) { $ordered.Add($r); [void] $pending.Remove($r) }
    }
    foreach ($r in $records) { if (-not $newNames.ContainsKey($r.EmployeeId)) { $ordered.Add($r) } }

    foreach ($r in $ordered) {
        $phase = Get-TurnstilePhase -Record $r -Today $Today -PrestartDays $Policy.prestartDays
        $user = $byEmployee[$r.EmployeeId]
        $first = if ($r.PreferredName) { $r.PreferredName } else { $r.FirstName }
        $location = $Policy.locations[$r.Location]
        $manager = & $usernameFor $r.ManagerId
        $desired = [ordered]@{
            givenName      = $first
            surname        = $r.LastName
            displayName    = "$first $($r.LastName)"
            title          = $r.JobTitle
            department     = $r.Department
            office         = $location.office
            manager        = $manager
            accountExpires = $(if ($r.EndDate) { Format-TurnstileDate $r.EndDate } else { $null })
            description    = ''
        }
        if (-not $manager) { $desired.Remove('manager') }   # unknown manager: leave as it is

        if ($phase -eq 'early') { continue }

        if ($phase -eq 'leaver') {
            if (-not $user) { continue }
            if ($user.enabled -or -not $user.disabledOn) {
                # (A disabled account with no disabledOn was made for someone who never started.)
                & $add 'Disable' $user.username $r "Left on $(Format-TurnstileDate $r.EndDate): disable the account" @{
                    description = "Left $(Format-TurnstileDate $r.EndDate). Disabled by Turnstile $(Format-TurnstileDate $Today)." }
            }
            foreach ($g in @($user.groups)) {
                & $add 'RemoveGroup' $user.username $r "Remove from $g (leaver)" (New-TurnstileRemoval -Group $g -Approvals $Approvals -EmployeeId $r.EmployeeId -Today $Today -Title $r.JobTitle)
            }
            if ($user.ou -ne $Policy.disabledOu) {
                & $add 'Move' $user.username $r "Move to the Disabled OU" @{ from = $user.ou; to = $Policy.disabledOu }
            }
            Add-TurnstileRetentionAction -Policy $Policy -User $user -Today $Today -Record $r -Add $add
            continue
        }

        # prestart or active
        $entitled = Get-TurnstileEntitlement -Policy $Policy -Record $r
        if (-not $user) {
            $username = $newNames[$r.EmployeeId]
            $starts = Format-TurnstileDate $r.StartDate -Long
            $create = [ordered]@{}
            foreach ($k in $desired.Keys) { $create[$k] = $desired[$k] }
            $create.manager = $manager
            $create.mail = "$username@$($Policy.domain)"
            $create.ou = $location.ou
            $create.enabled = ($phase -eq 'active')
            $detail = if ($phase -eq 'active') { "New starter: $($r.JobTitle), $($r.Department), $($r.Location)" }
                else { "New starter on $starts`: $($r.JobTitle), $($r.Department), $($r.Location). Created now, disabled until then" }
            & $add 'Create' $username $r $detail $create
            foreach ($g in $entitled) { Add-TurnstileGrant -Policy $Policy -Group $g -Username $username -Record $r -Add $add -Note $note -Approvals $Approvals -Today $Today -Held $false }
            continue
        }

        if (-not $user.enabled) {
            # Only switch on what Turnstile switched off (a leaver) or created switched off (a
            # new starter). An account someone disabled by hand, say to lock it during a
            # security incident, stays disabled until a person decides otherwise.
            $created = ConvertTo-TurnstileDate $user['created']
            if ($phase -eq 'active') {
                if ($user.disabledOn) {
                    $why = if ($r.StartDate -gt (ConvertTo-TurnstileDate $user.disabledOn)) { 'Rehired: enable the account' } else { 'HR no longer has an end date: enable the account again' }
                    & $add 'Enable' $user.username $r $why @{}
                } elseif ($created -and $created -lt $r.StartDate) {
                    & $add 'Enable' $user.username $r 'Starts today: enable the account' @{}
                } else {
                    & $note 'Warning' $r.EmployeeId "$($user.username) is disabled, but HR says they're working. Turnstile didn't disable it (perhaps a security lock-out), so it was left disabled: check with IT security."
                    continue
                }
            }
        } elseif ($phase -eq 'prestart') {
            & $note 'Warning' $r.EmployeeId "$($user.username) is enabled, but HR now says they start on $(Format-TurnstileDate $r.StartDate). Left enabled; check with HR."
        }
        if ($user.ou -ne $location.ou) {
            & $add 'Move' $user.username $r "Move to the $($r.Location) OU" @{ from = $user.ou; to = $location.ou }
        }
        $changes = [ordered]@{}
        foreach ($k in $script:AttributeOrder) {
            if (-not $desired.Contains($k)) { continue }
            $old = $user[$k]; $new = $desired[$k]
            if ((Test-TurnstileBlank $old) -and (Test-TurnstileBlank $new)) { continue }
            if ("$old" -cne "$new") { $changes[$k] = @{ old = $old; new = $new } }
        }
        if ($changes.Count) {
            $what = ($changes.Keys | ForEach-Object {
                $c = $changes[$_]
                if ($_ -eq 'description') { 'clear the leaver note' }
                elseif (Test-TurnstileBlank $c.new) { "clear $_" }
                else { "$_ '$($c.old)' -> '$($c.new)'" } }) -join ', '
            & $add 'Update' $user.username $r "Update $what" $changes
        }
        foreach ($g in $entitled) {
            $held = $user.groups -contains $g
            if (-not $held -or (Test-TurnstilePrivileged -Policy $Policy -Group $g)) {
                Add-TurnstileGrant -Policy $Policy -Group $g -Username $user.username -Record $r -Add $add -Note $note -Approvals $Approvals -Today $Today -Held $held
            }
        }
        foreach ($g in @($user.groups)) {
            if ($entitled -contains $g) { continue }
            if ($managedGroups -contains $g -or (Test-TurnstilePrivileged -Policy $Policy -Group $g)) {
                & $add 'RemoveGroup' $user.username $r "Remove from $g (no longer part of their job)" (New-TurnstileRemoval -Group $g -Approvals $Approvals -EmployeeId $r.EmployeeId -Today $Today -Title $r.JobTitle)
            } else {
                & $note 'Warning' $r.EmployeeId "$($user.username) is in $g, which isn't part of their job. It was added by hand, so it was left alone: please review it."
            }
        }
    }

    # People in the directory who aren't in today's export.
    $missingEnabled = 0
    foreach ($u in $managed) {
        if ($byId.ContainsKey($u.employeeId) -or $rejected.Contains($u.employeeId)) { continue }
        if ($u.enabled) {
            $missingEnabled++
            & $note 'Warning' $u.employeeId "$($u.username) isn't in today's HR export, so the account was left alone. Check with HR."
        } else {
            Add-TurnstileRetentionAction -Policy $Policy -User $u -Today $Today -Add $add `
                -Record ([pscustomobject]@{ EmployeeId = $u.employeeId; displayName = $u.displayName })
        }
    }
    foreach ($id in $rejected) {
        if ($byEmployee.ContainsKey($id)) { & $note 'Warning' $id "$($byEmployee[$id].username) was not changed, because their row in the export was rejected." }
    }

    # Safety stops: a broken export must never be able to lock out the company.
    $enabledManaged = @($managed | Where-Object enabled).Count
    $blocked = $null
    if ($enabledManaged -gt 0 -and $records.Count -eq 0) {
        $blocked = 'The HR export has no usable rows.'
    } elseif ($enabledManaged -gt 0 -and ($missingEnabled * 100 / $enabledManaged) -gt $Policy.safety.maxMissingPercent) {
        $blocked = "The HR export looks incomplete: $missingEnabled of $enabledManaged current staff aren't in it (the limit is $($Policy.safety.maxMissingPercent)%)."
    }
    if (-not $blocked -and $Approvals -and $Approvals.AuditProblem) {
        $blocked = "The audit log fails its check ($($Approvals.AuditProblem)) Find out why before running again."
    }
    $disables = @($actions | Where-Object Kind -eq 'Disable').Count
    $limit = [Math]::Max([int] $Policy.safety.minDisableLimit, [int] [Math]::Ceiling($enabledManaged * $Policy.safety.maxDisablePercent / 100))
    if (-not $blocked -and $disables -gt $limit) {
        $blocked = "This would disable $disables accounts at once (the limit is $limit). That usually means a mistake in the HR export."
    }

    $summary = [ordered]@{}
    foreach ($k in 'Create', 'Enable', 'Update', 'Move', 'AddGroup', 'RemoveGroup', 'Disable', 'Delete') {
        $summary[$k] = @($actions | Where-Object { $_.Kind -eq $k -and $_.Status -eq 'Ready' }).Count
    }
    $summary.NeedsApproval = @($actions | Where-Object Status -eq 'NeedsApproval').Count

    [pscustomobject]@{
        Today          = $Today
        HrPath         = $Feed.Path
        HrRows         = $Feed.RowCount
        Actions        = @($actions)
        Issues         = @($issues)
        Blocked        = [bool] $blocked
        BlockedReason  = $blocked
        Summary        = $summary
        ManagedCount   = $managed.Count
        UnmanagedCount = $allUsers.Count - $managed.Count
    }
}

function Add-TurnstileGrant {
    <#
        An ordinary group is simply added. A privileged group depends on its approval:
          not held yet:  approved and in date -> add it; otherwise wait for approval
          already held:  approved and in date -> nothing to do
                         expired               -> remove it, and ask again
                         denied or revoked     -> remove it
                         nothing on record     -> keep it for now, but ask for it to be confirmed
    #>
    param($Policy, $Group, $Username, $Record, $Add, $Note, $Approvals, [datetime] $Today, [bool] $Held)
    if (-not (Test-TurnstilePrivileged -Policy $Policy -Group $Group)) {
        & $Add 'AddGroup' $Username $Record "Add to $Group" @{ group = $Group }
        return
    }
    $st = Get-TurnstileApprovalState -View $Approvals -EmployeeId $Record.EmployeeId -Group $Group -Today $Today -Title $Record.JobTitle
    $req = $st.Request
    $waiting = { param($kind, $detail)
        $data = @{ group = $Group; kind = $kind; title = $Record.JobTitle }
        if ($st.State -eq 'Pending') { $data.approvalId = $req.id; $detail = "$detail (waiting on $($req.id) since $($req.requestedOn))" }
        & $Add $(if ($kind -eq 'Confirm') { 'Confirm' } else { 'AddGroup' }) $Username $Record $detail $data 'NeedsApproval' }
    if ($st.State -eq 'Unbacked') {
        & $Note 'Error' $Record.EmployeeId "$($req.id) is marked approved in the approvals file, but the audit log has no matching approval, so it's being ignored. Has the file been edited?"
    }

    if (-not $Held) {
        switch ($st.State) {
            'Valid' { & $Add 'AddGroup' $Username $Record "Add to $Group (approved: $($req.id) by $($req.decidedBy), ticket $($req.ticket), until $($req.expiresOn))" @{ group = $Group; approvalId = $req.id } }
            'Rejected' { & $Note 'Info' $Record.EmployeeId "$Username isn't being added to ${Group}: $($req.id) was $($req.status.ToLower()) by $($req.decidedBy) on $($req.decidedOn)." }
            default { & $waiting 'Add' "Add to ${Group}: privileged, so it needs approval first" }
        }
        return
    }
    switch ($st.State) {
        'Valid' { }
        'Expired' {
            & $Add 'RemoveGroup' $Username $Record "Remove from ${Group}: approval $($req.id) expired on $($req.expiresOn)" @{ group = $Group; approvalId = $req.id; endStatus = 'Expired' }
            & $waiting 'Add' "Add to ${Group} again: needs a new approval"
        }
        'Rejected' {
            & $Add 'RemoveGroup' $Username $Record "Remove from ${Group}: $($req.id) was $($req.status.ToLower()) by $($req.decidedBy)" @{ group = $Group; approvalId = $req.id }
        }
        default { & $waiting 'Confirm' "Already in $Group with no approval on record: needs confirming (kept meanwhile)" }
    }
}

function New-TurnstileRemoval {
    # Data for removing a group; if a current approval covered it, that approval ends too.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Makes a new value; changes nothing.')]
    param([string] $Group, $Approvals, [string] $EmployeeId, [datetime] $Today, [string] $Title)
    $data = @{ group = $Group }
    $st = Get-TurnstileApprovalState -View $Approvals -EmployeeId $EmployeeId -Group $Group -Today $Today -Title $Title
    if ($st.State -in 'Valid', 'Expired') { $data.approvalId = $st.Request.id; $data.endStatus = 'Ended' }
    $data
}

function Add-TurnstileRetentionAction {
    # A leaver's disabled account is deleted once the retention period has passed.
    param($Policy, $User, [datetime] $Today, $Record, $Add)
    if ($User.enabled -or -not $User.disabledOn) { return }
    $disabled = ConvertTo-TurnstileDate $User.disabledOn
    if ($disabled -and $Today -ge $disabled.AddDays($Policy.leaverRetentionDays)) {
        & $Add 'Delete' $User.username $Record "Delete: disabled since $($User.disabledOn), past the $($Policy.leaverRetentionDays)-day retention period" @{ disabledOn = $User.disabledOn }
    }
}
