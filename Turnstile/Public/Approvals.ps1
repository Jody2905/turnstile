function Get-TurnstileApproval {
    <#
    .SYNOPSIS
        List approval requests, newest last. -Status Pending shows what's waiting for a decision.
    .EXAMPLE
        Get-TurnstileApproval -DirectoryPath .\demo-output\directory.json -Status Pending
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $DirectoryPath,
        [string] $ApprovalPath,
        [ValidateSet('Pending', 'Approved', 'Rejected', 'Revoked', 'Expired', 'Ended', 'Cancelled')][string] $Status
    )
    $directory = Open-TurnstileDirectory -Path $DirectoryPath
    $paths = Get-TurnstilePaths -Directory $directory -ApprovalPath $ApprovalPath
    $store = Open-TurnstileApprovals -Path $paths.Approvals
    foreach ($r in $store.State.requests) {
        if ($Status -and $r.status -ne $Status) { continue }
        [pscustomobject]@{
            Id = $r.id; Status = $r.status; Username = $r.username; Name = $r.name; Group = $r.group; Kind = $r.kind
            Title = $r.title; RequestedOn = $r.requestedOn; DecidedBy = $r.decidedBy; DecidedOn = $r.decidedOn
            Ticket = $r.ticket; ExpiresOn = $r.expiresOn; Note = $r.note
        }
    }
}

function Invoke-TurnstileDecision {
    # Shared by Approve, Deny and Revoke: check the decider, record the decision in the audit
    # log first (that's what makes it count), then in approvals.json.
    param($DirectoryPath, $PolicyPath, $ApprovalPath, $AuditPath, $Id, $By, [datetime] $Today, [string[]] $From, [scriptblock] $Decide, $Cmdlet, $Verb)
    $policy = Read-TurnstilePolicy -Path $PolicyPath
    $directory = Open-TurnstileDirectory -Path $DirectoryPath
    $paths = Get-TurnstilePaths -Directory $directory -ApprovalPath $ApprovalPath -AuditPath $AuditPath
    $store = Open-TurnstileApprovals -Path $paths.Approvals
    $request = $store.State.requests | Where-Object id -eq $Id | Select-Object -First 1
    if (-not $request) { throw "There's no approval request $Id." }
    if ($request.status -notin $From) { throw "$Id is $($request.status.ToLower()), so it can't be $Verb." }
    $why = Test-TurnstileApprover -Policy $policy -Directory $directory -Request $request -Approver $By
    if ($why) { throw $why }
    if (-not $Cmdlet.ShouldProcess("$Id ($($request.username), $($request.group))", $Verb)) { return }
    $event = & $Decide $request $policy
    Add-TurnstileAuditEntry -Path $paths.Audit -RunId "decision-$Id" -Event $event.Name -Target $request.username -Detail $event.Detail -Data $event.Data
    Save-TurnstileApprovals -Store $store
    Get-TurnstileApproval -DirectoryPath $DirectoryPath -ApprovalPath $paths.Approvals | Where-Object Id -eq $Id
}

function Approve-TurnstileAccess {
    <#
    .SYNOPSIS
        Approve a request for a privileged group. The access is added on the next run.
    .DESCRIPTION
        Only the person's line manager or the group's owner (from the policy) can approve, never
        the person themselves. A change ticket is required. The approval lasts -Days days
        (90 by default, at most 365), then the access is removed and a new request raised.
    .EXAMPLE
        Approve-TurnstileAccess -DirectoryPath .\demo-output\directory.json -Id APR-0001 -ApprovedBy dwight.robertson -Ticket CHG-1042
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string] $DirectoryPath,
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $ApprovedBy,
        [Parameter(Mandatory)][string] $Ticket,
        [int] $Days,
        [string] $Note = '',
        [string] $PolicyPath = $script:DefaultPolicy,
        [string] $ApprovalPath,
        [string] $AuditPath,
        [datetime] $Today = (Get-Date).Date
    )
    Invoke-TurnstileDecision -DirectoryPath $DirectoryPath -PolicyPath $PolicyPath -ApprovalPath $ApprovalPath -AuditPath $AuditPath `
        -Id $Id -By $ApprovedBy -Today $Today -From 'Pending' -Cmdlet $PSCmdlet -Verb 'approved' -Decide {
        param($request, $policy)
        if ($Ticket -notmatch $policy.approvals.ticketPattern) { throw "Ticket '$Ticket' doesn't look like a change ticket (for example CHG-1042)." }
        $length = if ($Days) { $Days } else { [int] $policy.approvals.defaultDays }
        if ($length -lt 1 -or $length -gt [int] $policy.approvals.maxDays) { throw "An approval can last from 1 to $($policy.approvals.maxDays) days." }
        $request.status = 'Approved'
        $request.decidedBy = $ApprovedBy
        $request.decidedOn = Format-TurnstileDate $Today
        $request.ticket = $Ticket
        $request.note = $Note
        $request.expiresOn = Format-TurnstileDate $Today.Date.AddDays($length)
        @{ Name = 'ApprovalGranted'
           Detail = "$($request.id): $($request.group) for $($request.username) approved by $ApprovedBy ($Ticket) until $($request.expiresOn)"
           Data = @{ id = $request.id; employeeId = $request.employeeId; group = $request.group; expiresOn = $request.expiresOn; ticket = $Ticket; by = $ApprovedBy } }
    }
}

function Deny-TurnstileAccess {
    <#
    .SYNOPSIS
        Turn down a request. It isn't asked again unless the person's job changes.
        Turning down a "confirm existing access" request removes that access on the next run.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string] $DirectoryPath,
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $DeniedBy,
        [Parameter(Mandatory)][string] $Reason,
        [string] $PolicyPath = $script:DefaultPolicy,
        [string] $ApprovalPath,
        [string] $AuditPath,
        [datetime] $Today = (Get-Date).Date
    )
    if ([string]::IsNullOrWhiteSpace($Reason)) { throw 'Please give a reason.' }
    Invoke-TurnstileDecision -DirectoryPath $DirectoryPath -PolicyPath $PolicyPath -ApprovalPath $ApprovalPath -AuditPath $AuditPath `
        -Id $Id -By $DeniedBy -Today $Today -From 'Pending' -Cmdlet $PSCmdlet -Verb 'denied' -Decide {
        param($request, $policy)
        $request.status = 'Rejected'
        $request.decidedBy = $DeniedBy
        $request.decidedOn = Format-TurnstileDate $Today
        $request.note = $Reason
        @{ Name = 'ApprovalDenied'; Detail = "$($request.id): $($request.group) for $($request.username) denied by ${DeniedBy}: $Reason"
           Data = @{ id = $request.id; by = $DeniedBy } }
    }
}

function Revoke-TurnstileAccess {
    <#
    .SYNOPSIS
        Take back approved access before it expires. It's removed on the next run.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string] $DirectoryPath,
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $RevokedBy,
        [Parameter(Mandatory)][string] $Reason,
        [string] $PolicyPath = $script:DefaultPolicy,
        [string] $ApprovalPath,
        [string] $AuditPath,
        [datetime] $Today = (Get-Date).Date
    )
    if ([string]::IsNullOrWhiteSpace($Reason)) { throw 'Please give a reason.' }
    Invoke-TurnstileDecision -DirectoryPath $DirectoryPath -PolicyPath $PolicyPath -ApprovalPath $ApprovalPath -AuditPath $AuditPath `
        -Id $Id -By $RevokedBy -Today $Today -From 'Approved' -Cmdlet $PSCmdlet -Verb 'revoked' -Decide {
        param($request, $policy)
        $request.status = 'Revoked'
        $request.decidedBy = $RevokedBy
        $request.decidedOn = Format-TurnstileDate $Today
        $request.note = $Reason
        @{ Name = 'ApprovalRevoked'; Detail = "$($request.id): $($request.group) for $($request.username) revoked by ${RevokedBy}: $Reason"
           Data = @{ id = $request.id; by = $RevokedBy } }
    }
}
