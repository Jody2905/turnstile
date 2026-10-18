# Approvals for privileged groups.
#
# The requests live in approvals.json, next to the directory. But that file alone proves
# nothing: anyone who can edit it could mark their own request "Approved". So an approval only
# counts if the hash-chained audit log holds a matching ApprovalGranted entry (same request,
# person, group and expiry date), and the log itself passes its check.
#
# A request's life:
#   Pending  -> Approved (by their manager or the group's owner, with a ticket, for N days)
#            -> Rejected (denied; not asked again unless their job changes)
#            -> Cancelled (no longer needed: they left, or changed job)
#   Approved -> Expired (the days ran out: access removed, a new request raised)
#            -> Revoked (taken back early: access removed)
#            -> Ended (no longer needed: they left or changed job)

function Open-TurnstileApprovalStore {
    param([Parameter(Mandatory)][string] $Path)
    $state = if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable } else { $null }
    if (-not $state) { $state = [ordered]@{ nextId = 1; requests = @() } }
    $state.requests = [Collections.Generic.List[object]]::new([object[]] @($state.requests))
    [pscustomobject]@{ Path = $Path; State = $state; Changed = $false }
}

function Save-TurnstileApprovalStore {
    param([Parameter(Mandatory)] $Store)
    $temp = "$($Store.Path).tmp"
    Set-Content -LiteralPath $temp -Value ($Store.State | ConvertTo-Json -Depth 6) -Encoding utf8NoBOM
    Move-Item -LiteralPath $temp -Destination $Store.Path -Force
    $Store.Changed = $false
}

function New-TurnstileApprovalRequest {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Makes a new value; changes nothing.')]
    param([Parameter(Mandatory)] $Store, [Parameter(Mandatory)] $Action, [Parameter(Mandatory)][datetime] $Today, [string] $Title, [string] $Kind)
    $id = 'APR-{0:0000}' -f [int] $Store.State.nextId
    $Store.State.nextId = [int] $Store.State.nextId + 1
    $request = [ordered]@{
        id = $id; kind = $Kind; employeeId = $Action.EmployeeId; username = $Action.Username; name = $Action.Name
        group = $Action.Data.group; title = $Title; status = 'Pending'; requestedOn = (Format-TurnstileDate $Today)
        decidedBy = $null; decidedOn = $null; ticket = $null; note = $null; expiresOn = $null; endedOn = $null
    }
    $Store.State.requests.Add($request)
    $Store.Changed = $true
    $request
}

function Get-TurnstileApprovalBacking {
    # What the audit log says was approved: request id -> employee, group and expiry.
    # Also whether the log passes its check; if it doesn't, no approval can be trusted.
    param([Parameter(Mandatory)][string] $AuditPath)
    $backing = @{}
    if (-not (Test-Path -LiteralPath $AuditPath)) { return [pscustomobject]@{ Backing = $backing; Problem = $null } }
    $check = Test-TurnstileAuditLog -Path $AuditPath
    if (-not $check.Valid) { return [pscustomobject]@{ Backing = @{}; Problem = $check.Problem } }
    foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $AuditPath).Path)) {
        if ($line -notlike '*"event":"Approval*') { continue }
        $entry = $line.Substring(65) | ConvertFrom-Json
        if ($entry.event -eq 'ApprovalGranted') {
            $backing[$entry.data.id] = @{ employeeId = $entry.data.employeeId; group = $entry.data.group; expiresOn = $entry.data.expiresOn }
        } elseif ($entry.event -in 'ApprovalRevoked', 'ApprovalEnded') {
            $backing.Remove($entry.data.id)
        }
    }
    [pscustomobject]@{ Backing = $backing; Problem = $null }
}

function Get-TurnstileApprovalView {
    # Everything the planner needs to know about approvals, read once.
    param([Parameter(Mandatory)] $Store, [Parameter(Mandatory)][string] $AuditPath)
    $b = Get-TurnstileApprovalBacking -AuditPath $AuditPath
    [pscustomobject]@{ Requests = @($Store.State.requests); Backing = $b.Backing; AuditProblem = $b.Problem }
}

function Get-TurnstileApprovalState {
    <#
        Where this person stands for this privileged group:
          Valid      approved, in date, and backed by the audit log
          Expired    approved, but the days have run out
          Unbacked   says approved, but the audit log disagrees: ignored
          Pending    waiting for a decision
          Rejected   denied (or revoked) for the job they have now
          None       nothing on record that still counts
    #>
    param($View, [string] $EmployeeId, [string] $Group, [datetime] $Today, [string] $Title)
    $latest = $null
    if ($View) {
        $latest = $View.Requests |
            Where-Object { $_.employeeId -eq $EmployeeId -and $_.group -eq $Group -and $_.status -notin 'Cancelled', 'Ended' } |
            Select-Object -Last 1
    }
    $result = { param($state) [pscustomobject]@{ State = $state; Request = $latest } }
    if (-not $latest) { return & $result 'None' }
    switch ($latest.status) {
        'Pending' { return & $result 'Pending' }
        'Approved' {
            $proof = $View.Backing[$latest.id]
            if (-not $proof -or $proof.employeeId -ne $latest.employeeId -or $proof.group -ne $latest.group -or $proof.expiresOn -ne $latest.expiresOn) {
                return & $result 'Unbacked'
            }
            if ($Today -gt (ConvertTo-TurnstileDate $latest.expiresOn)) { return & $result 'Expired' }
            return & $result 'Valid'
        }
        { $_ -in 'Rejected', 'Revoked' } {
            if ($latest.title -eq $Title) { return & $result 'Rejected' }
            return & $result 'None'
        }
        default { return & $result 'None' }
    }
}

function Test-TurnstileApprover {
    # Who may decide: the person's line manager, or the group's owner (approvals.groupOwners in the policy).
    # Never the person themselves, and only from an enabled account. Returns why not, or $null.
    param($Policy, $Directory, $Request, [string] $Approver)
    $who = Get-TurnstileDirectoryUser $Directory -Username $Approver
    if (-not $who) { return "There's no account called $Approver." }
    if (-not $who.employeeId) { return "$Approver isn't a person's account, so it can't approve anything." }
    if (-not $who.enabled) { return "$Approver is disabled, so it can't approve anything." }
    if ($who.username -eq $Request.username -or $who.employeeId -eq $Request.employeeId) { return 'Nobody can approve their own access.' }
    $target = Get-TurnstileDirectoryUser $Directory -Username $Request.username
    $isManager = $target -and $target['manager'] -eq $who.username
    $isOwner = $Policy.approvals.groupOwners.Contains($Request.group) -and $Policy.approvals.groupOwners[$Request.group] -eq $who.employeeId
    if (-not ($isManager -or $isOwner)) {
        return "$Approver isn't $($Request.username)'s manager or the owner of $($Request.group), so they can't decide this."
    }
    $null
}
