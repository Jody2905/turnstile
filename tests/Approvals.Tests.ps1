BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $andre = New-HrRow @{ EmployeeId = 'E1022'; FirstName = 'Andre'; LastName = 'Cupid'; Department = 'IT'; JobTitle = 'Systems Administrator'; ManagerId = 'E1016'; StartDate = '2026-10-19' }

    function Approve([string] $Id, [string] $By, [datetime] $Today = '2026-10-19', [hashtable] $Extra = @{}) {
        $ticket = if ($Extra.ContainsKey('Ticket')) { $Extra.Ticket } else { 'CHG-1042' }
        $Extra.Remove('Ticket')
        Approve-TurnstileAccess -DirectoryPath (Join-Path $TestDrive 'directory.json') -PolicyPath $PolicyPath -Id $Id -ApprovedBy $By -Ticket $ticket -Today $Today -Confirm:$false @Extra
    }
    function Deny([string] $Id, [string] $By, [datetime] $Today = '2026-10-19') {
        Deny-TurnstileAccess -DirectoryPath (Join-Path $TestDrive 'directory.json') -PolicyPath $PolicyPath -Id $Id -DeniedBy $By -Reason 'Not needed for this role yet' -Today $Today -Confirm:$false
    }
    function Revoke([string] $Id, [string] $By, [datetime] $Today) {
        Revoke-TurnstileAccess -DirectoryPath (Join-Path $TestDrive 'directory.json') -PolicyPath $PolicyPath -Id $Id -RevokedBy $By -Reason 'Project finished' -Today $Today -Confirm:$false
    }
    function Requests([string] $Username) {
        @(Get-TurnstileApproval -DirectoryPath (Join-Path $TestDrive 'directory.json') | Where-Object { -not $Username -or $_.Username -eq $Username })
    }
    function Edit-Approvals([scriptblock] $Change) {
        $path = Join-Path $TestDrive 'approvals.json'
        $state = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        & $Change $state
        Set-Content $path ($state | ConvertTo-Json -Depth 6)
    }
}

Describe 'Asking for privileged access' {
    BeforeEach { $staff = Initialize-Staff }

    It 'raises one request per person and group, however many times it runs' {
        $run = Sync -Rows ($staff + $andre) -Today '2026-10-19'
        (Get-ActionsFor $run 'andre.cupid' | Where-Object Status -eq 'NeedsApproval').Detail | Should -BeLike '*needs approval first (request APR-000? raised)'
        $null = Sync -Rows ($staff + $andre) -Today '2026-10-20'
        $mine = Requests 'andre.cupid'
        $mine.Count | Should -Be 1
        $mine[0].Status | Should -Be 'Pending'
        $mine[0].Group | Should -Be 'Server Admins'
        $mine[0].Kind | Should -Be 'Add'
        $mine[0].Title | Should -Be 'Systems Administrator'
        @(Get-AuditEvents | Where-Object { $_.event -eq 'ApprovalRequested' -and $_.target -eq 'andre.cupid' }).Count | Should -Be 1
    }

    It 'turns a request into a confirmation if someone adds the group by hand meanwhile' {
        $null = Sync -Rows ($staff + $andre) -Today '2026-10-19'
        Set-DirectoryUser 'andre.cupid' { param($u) $u.groups += 'Server Admins' }
        $null = Sync -Rows ($staff + $andre) -Today '2026-10-20'
        (Requests 'andre.cupid').Kind | Should -Be 'Confirm'
    }

    It 'asks for access held from before Turnstile to be confirmed, and keeps it meanwhile' {
        $null = Sync -Rows $staff -Today '2026-10-19'
        $lystra = Requests 'lystra.baptiste'
        $lystra.Kind | Should -Be 'Confirm'
        $lystra.Group | Should -Be 'Finance Approvers'
        (Get-User 'lystra.baptiste').groups | Should -Contain 'Finance Approvers'
    }

    It 'with -WhatIf, raises nothing' {
        $null = Sync -Rows ($staff + $andre) -Today '2026-10-19' -Extra @{ WhatIf = $true } 6>$null
        Test-Path (Join-Path $TestDrive 'approvals.json') | Should -BeFalse
    }
}

Describe 'Who can decide' {
    BeforeEach {
        $staff = Initialize-Staff
        $null = Sync -Rows ($staff + $andre) -Today '2026-10-19'
        $id = (Requests 'andre.cupid').Id
    }

    It 'not the person themselves' { { Approve $id 'andre.cupid' } | Should -Throw 'Nobody can approve their own access.' }
    It 'not someone who is neither their manager nor the group''s owner' {
        { Approve $id 'carla.bowman' } | Should -Throw "carla.bowman isn't andre.cupid's manager or the owner of Server Admins, so they can't decide this."
    }
    It 'not a service account, a disabled account, or someone who doesn''t exist' {
        { Approve $id 'Administrator' } | Should -Throw "*isn't a person's account*"
        { Approve $id 'nobody.here' } | Should -Throw "There's no account called nobody.here."
        Set-DirectoryUser 'dwight.robertson' { param($u) $u.enabled = $false }
        { Approve $id 'dwight.robertson' } | Should -Throw '*is disabled*'
    }
    It 'needs a change ticket and a sensible length' {
        { Approve $id 'dwight.robertson' -Extra @{ Ticket = 'asked in the corridor' } } | Should -Throw "*doesn't look like a change ticket*"
        { Approve $id 'dwight.robertson' -Extra @{ Days = 400 } } | Should -Throw '*from 1 to 365 days*'
    }
    It 'their manager can approve, for 90 days by default' {
        $r = Approve $id 'dwight.robertson'
        $r.Status | Should -Be 'Approved'
        $r.ExpiresOn | Should -Be '2027-01-17'
        $r.Ticket | Should -Be 'CHG-1042'
        { Approve $id 'dwight.robertson' } | Should -Throw "$id is approved, so it can't be approved."
    }
    It 'the group''s owner can approve, even when they aren''t the manager' {
        # Payroll belongs to Lystra (E1002); this payroll officer reports to Garfield.
        $ronald = New-HrRow @{ EmployeeId = 'E1004'; FirstName = 'Ronald'; LastName = 'Cottle'; JobTitle = 'Payroll Officer'; ManagerId = 'E1001'; StartDate = '2026-10-19' }
        $null = Sync -Rows ($staff + $andre + $ronald) -Today '2026-10-19'
        (Approve (Requests 'ronald.cottle').Id 'lystra.baptiste').Status | Should -Be 'Approved'
    }
    It '-WhatIf decides nothing' {
        Approve-TurnstileAccess -DirectoryPath (Join-Path $TestDrive 'directory.json') -PolicyPath $PolicyPath -Id $id -ApprovedBy dwight.robertson -Ticket CHG-1042 -Today '2026-10-19' -WhatIf 6>$null
        (Requests 'andre.cupid').Status | Should -Be 'Pending'
    }
}

Describe 'What decisions do' {
    BeforeEach {
        $staff = Initialize-Staff
        $rows = $staff + $andre
        $null = Sync -Rows $rows -Today '2026-10-19'
        $id = (Requests 'andre.cupid').Id
    }

    It 'approved: added on the next run, with the approval in the plan and the audit log' {
        $null = Approve $id 'dwight.robertson'
        $run = Sync -Rows $rows -Today '2026-10-20'
        (Get-ActionsFor $run 'andre.cupid').Detail | Should -Be @("Add to Server Admins (approved: $id by dwight.robertson, ticket CHG-1042, until 2027-01-17)")
        (Get-User 'andre.cupid').groups | Should -Contain 'Server Admins'
        $granted = Get-AuditEvents | Where-Object event -eq 'ApprovalGranted'
        $granted.data.id | Should -Be $id
        $granted.data.expiresOn | Should -Be '2027-01-17'
        Get-ReadyActions (Sync -Rows $rows -Today '2026-10-21') | Should -BeNullOrEmpty
    }

    It 'expired: removed the day after it ends, and asked for again' {
        $null = Approve $id 'dwight.robertson' -Extra @{ Days = 30 }
        $null = Sync -Rows $rows -Today '2026-10-20'
        $null = Sync -Rows $rows -Today '2026-11-18'           # the last day
        (Get-User 'andre.cupid').groups | Should -Contain 'Server Admins'
        $run = Sync -Rows $rows -Today '2026-11-19'
        (Get-ActionsFor $run 'andre.cupid' | Where-Object Status -eq 'Ready').Detail | Should -Be @("Remove from Server Admins: approval $id expired on 2026-11-18")
        (Get-User 'andre.cupid').groups | Should -Not -Contain 'Server Admins'
        $mine = Requests 'andre.cupid'
        $mine[0].Status | Should -Be 'Expired'
        $mine[1].Status | Should -Be 'Pending'
    }

    It 'denied: not added, and not asked again for the same job' {
        $null = Deny $id 'dwight.robertson'
        $run = Sync -Rows $rows -Today '2026-10-20'
        (Get-User 'andre.cupid').groups | Should -Not -Contain 'Server Admins'
        $run.Plan.Issues.Message | Should -Contain "andre.cupid isn't being added to Server Admins: $id was rejected by dwight.robertson on 2026-10-19."
        $null = Sync -Rows $rows -Today '2026-10-21'
        (Requests 'andre.cupid').Count | Should -Be 1
    }

    It 'revoked: removed on the next run' {
        $null = Approve $id 'dwight.robertson'
        $null = Sync -Rows $rows -Today '2026-10-20'
        { Revoke $id 'andre.cupid' '2026-10-22' } | Should -Throw 'Nobody can approve their own access.'
        $null = Revoke $id 'dwight.robertson' '2026-10-22'
        $run = Sync -Rows $rows -Today '2026-10-22'
        (Get-ActionsFor $run 'andre.cupid').Detail | Should -Be @("Remove from Server Admins: $id was revoked by dwight.robertson")
        (Get-User 'andre.cupid').groups | Should -Not -Contain 'Server Admins'
    }

    It 'confirming access held from before Turnstile: approved, it stays; denied, it goes' {
        $lystra = (Requests 'lystra.baptiste').Id
        $null = Approve $lystra 'garfield.providence'
        Get-ActionsFor (Sync -Rows $rows -Today '2026-10-20') 'lystra.baptiste' | Should -BeNullOrEmpty
        (Get-User 'lystra.baptiste').groups | Should -Contain 'Finance Approvers'

        $null = Initialize-Staff
        $null = Sync -Rows $rows -Today '2026-10-19'
        $null = Deny (Requests 'lystra.baptiste').Id 'garfield.providence'
        $null = Sync -Rows $rows -Today '2026-10-20'
        (Get-User 'lystra.baptiste').groups | Should -Not -Contain 'Finance Approvers'
    }

    It 'leaving ends the approval; a job change cancels a waiting request' {
        $null = Approve $id 'dwight.robertson'
        $null = Sync -Rows $rows -Today '2026-10-20'
        $null = Sync -Rows (Set-Row $rows 'E1022' @{ EndDate = '2026-10-20' }) -Today '2026-10-21'
        (Requests 'andre.cupid').Status | Should -Be 'Ended'
        (Get-AuditEvents | Where-Object event -eq 'ApprovalEnded').target | Should -Be 'andre.cupid'

        $null = Sync -Rows (Set-Row $rows 'E1002' @{ JobTitle = 'Accounts Assistant' }) -Today '2026-10-22'
        (Requests 'lystra.baptiste').Status | Should -Be 'Cancelled'
    }
}

Describe 'Approvals that don''t add up' {
    BeforeEach {
        $staff = Initialize-Staff
        $rows = $staff + $andre
        $null = Sync -Rows $rows -Today '2026-10-19'
        $id = (Requests 'andre.cupid').Id
    }

    It 'an approval typed into approvals.json by hand is ignored, and reported' {
        Edit-Approvals { param($s) $r = $s.requests | Where-Object id -eq $id
            $r.status = 'Approved'; $r.decidedBy = 'dwight.robertson'; $r.ticket = 'CHG-9999'; $r.expiresOn = '2027-12-31' }
        $run = Sync -Rows $rows -Today '2026-10-20'
        (Get-User 'andre.cupid').groups | Should -Not -Contain 'Server Admins'
        $run.Plan.Issues | Where-Object Severity -eq 'Error' | ForEach-Object Message | Should -BeLike "$id is marked approved in the approvals file, but the audit log has no matching approval*"
    }

    It 'stretching a real approval''s end date by editing the file makes it stop counting' {
        $null = Approve $id 'dwight.robertson'
        $null = Sync -Rows $rows -Today '2026-10-20'
        Edit-Approvals { param($s) ($s.requests | Where-Object id -eq $id).expiresOn = '2030-01-01' }
        $run = Sync -Rows $rows -Today '2026-10-21'
        (Get-ActionsFor $run 'andre.cupid').Kind | Should -Be @('Confirm')
        $run.Plan.Issues.Message | Should -Contain "$id is marked approved in the approvals file, but the audit log has no matching approval, so it's being ignored. Has the file been edited?"
    }

    It 'a tampered audit log stops the run' {
        $null = Approve $id 'dwight.robertson'
        $log = Join-Path $TestDrive 'audit.log'
        $lines = Get-Content $log
        $lines[0] = $lines[0] -replace 'RunStarted', 'RunStartex'
        Set-Content $log $lines
        $run = Sync -Rows $rows -Today '2026-10-20'
        $run.Refused | Should -BeTrue
        $run.Plan.BlockedReason | Should -BeLike 'The audit log fails its check (Line 1: the entry was changed after it was written.)*'
        (Get-User 'andre.cupid').groups | Should -Not -Contain 'Server Admins'
    }
}

Describe 'The access review' {
    BeforeEach {
        $staff = Initialize-Staff
        $rows = $staff + $andre
        $null = Sync -Rows $rows -Today '2026-10-19'
        $directory = Join-Path $TestDrive 'directory.json'
        $review = { param($day = '2026-10-19', $hr = $null)
            $p = @{ DirectoryPath = $directory; PolicyPath = $PolicyPath; Today = $day }
            if ($hr) { $p.HrPath = $hr }
            Get-TurnstileAccessReview @p }
    }

    It 'flags each kind of risk' {
        Set-DirectoryUser 'jerome.delves' { param($u) $u.groups += 'Ferry Terminal Project' }
        $null = Approve (Requests 'andre.cupid').Id 'dwight.robertson' '2026-10-19' -Extra @{ Days = 10 }
        $null = Sync -Rows $rows -Today '2026-10-20'
        Set-DirectoryUser 'carla.bowman' { param($u) $u.enabled = $false }
        $hr = Write-Hr -Rows @($rows | Where-Object EmployeeId -ne 'E1013') -Name 'review.csv'
        $r = & $review '2026-10-23' $hr
        $found = $r.Findings | ForEach-Object { "$($_.Severity)|$($_.Category)|$($_.Username)" }
        $found | Should -Contain 'High|Privileged without approval|lystra.baptiste'
        $found | Should -Contain 'Medium|Disabled with access|carla.bowman'
        $found | Should -Contain 'Medium|Granted by hand|jerome.delves'
        $found | Should -Contain 'Medium|Not in HR export|jerome.delves'
        $found | Should -Contain 'Medium|Waiting too long|lystra.baptiste'
        $found | Should -Contain 'Medium|Service account with privileges|Administrator'
        $found | Should -Contain 'Low|Approval ending soon|andre.cupid'
        $found | Should -Contain 'Low|No employee ID|svc-backup'
        $r.Findings[0].Severity | Should -Be 'High'
    }

    It 'flags a leaver still in groups as high, and leaves new starters alone' {
        $zoe = New-HrRow @{ EmployeeId = 'E1020'; FirstName = 'Zoë'; LastName = 'Ollivierre'; StartDate = '2026-10-26' }
        $hr = Write-Hr -Rows ($rows + $zoe) -Name 'review.csv'
        $null = Sync -Rows ($rows + $zoe) -Today '2026-10-20'
        $null = Sync -Rows (Set-Row $rows 'E1006' @{ EndDate = '2026-10-19' }) -Today '2026-10-20'
        Set-DirectoryUser 'desmond.hazell' { param($u) $u.groups = @('Port Ops') }
        $found = (& $review '2026-10-21' $hr).Findings | ForEach-Object { "$($_.Severity)|$($_.Category)|$($_.Username)" }
        $found | Should -Contain 'High|Disabled with access|desmond.hazell'
        $found | Should -Not -Contain 'Medium|Disabled with access|zoe.ollivierre'
    }

    It 'says where each membership came from' {
        $null = Approve (Requests 'andre.cupid').Id 'dwight.robertson'
        $null = Sync -Rows $rows -Today '2026-10-20'
        Set-DirectoryUser 'jerome.delves' { param($u) $u.groups += 'Ferry Terminal Project' }
        $hr = Write-Hr -Rows $rows -Name 'review.csv'
        $e = (& $review '2026-10-20' $hr).Entries
        ($e | Where-Object { $_.Username -eq 'andre.cupid' -and $_.Group -eq 'Server Admins' }).Source | Should -BeLike 'Approved (APR-*)'
        ($e | Where-Object { $_.Username -eq 'andre.cupid' -and $_.Group -eq 'IT Team' }).Source | Should -Be 'Their job'
        ($e | Where-Object { $_.Username -eq 'jerome.delves' -and $_.Group -eq 'Ferry Terminal Project' }).Source | Should -Be 'Granted by hand'
        ($e | Where-Object { $_.Username -eq 'lystra.baptiste' -and $_.Group -eq 'Finance Approvers' }).Source | Should -BeLike 'Waiting for approval (APR-*)'
        ($e | Where-Object Username -eq 'Administrator').Source | Should -Be 'Service account'
        ($e | Where-Object Username -eq 'andre.cupid')[0].Manager | Should -Be 'Dwight Robertson (dwight.robertson)'
    }

    It 'catches an approval that the audit log doesn''t back up' {
        $id = (Requests 'andre.cupid').Id
        $null = Approve $id 'dwight.robertson'
        $null = Sync -Rows $rows -Today '2026-10-20'
        Edit-Approvals { param($s) ($s.requests | Where-Object id -eq $id).expiresOn = '2030-01-01' }
        (& $review '2026-10-20').Findings | Where-Object Category -eq 'Approval not in audit log' | ForEach-Object Username | Should -Be 'andre.cupid'
    }

    It 'changes nothing' {
        $before = @('directory.json', 'approvals.json', 'audit.log') | ForEach-Object { (Get-FileHash (Join-Path $TestDrive $_)).Hash }
        $null = & $review '2026-10-25'
        $after = @('directory.json', 'approvals.json', 'audit.log') | ForEach-Object { (Get-FileHash (Join-Path $TestDrive $_)).Hash }
        $after | Should -Be $before
    }

    It 'exports CSVs for managers, with a Decision column and no formulas Excel would run' {
        Set-DirectoryUser 'jerome.delves' { param($u) $u.title = '=HYPERLINK("http://evil.example","Click me")' }
        $files = & $review | Export-TurnstileAccessReview -Folder (Join-Path $TestDrive 'review')
        $files.Count | Should -Be 2
        $rowsOut = Import-Csv $files[1]
        $rowsOut[0].PSObject.Properties.Name | Should -Contain 'Decision'
        ($rowsOut | Where-Object Username -eq 'jerome.delves')[0].Title | Should -Be "'=HYPERLINK(""http://evil.example"",""Click me"")"
        (Import-Csv $files[0]).Count | Should -BeGreaterThan 0
    }
}
