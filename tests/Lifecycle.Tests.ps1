BeforeAll { . (Join-Path $PSScriptRoot 'TestHelpers.ps1') }

Describe 'Joiners' {
    BeforeEach { $staff = Initialize-Staff }

    It 'creates an enabled account with the job''s groups on the first day' {
        $zoe = New-HrRow @{ EmployeeId = 'E1020'; FirstName = 'Zoë'; LastName = 'Ollivierre'; ManagerId = 'E1002'; StartDate = '2026-10-19' }
        $run = Sync -Rows ($staff + $zoe) -Today '2026-10-19'
        $run.Failed | Should -Be 0
        $u = Get-User 'zoe.ollivierre'
        $u.enabled | Should -BeTrue
        $u.employeeId | Should -Be 'E1020'
        $u.displayName | Should -Be 'Zoë Ollivierre'
        $u.mail | Should -Be 'zoe.ollivierre@windwardfreight.example'
        $u.ou | Should -Be $KingstownOu
        $u.manager | Should -Be 'lystra.baptiste'
        $u.mustChangePassword | Should -BeTrue
        $u.groups | Should -Be @('All Staff', 'Finance', 'Finance Share', 'Kingstown Office')
    }

    It 'creates it disabled up to 7 days before the start, and enables it on the day' {
        $zoe = New-HrRow @{ EmployeeId = 'E1020'; FirstName = 'Zoë'; LastName = 'Ollivierre'; StartDate = '2026-10-26' }
        $null = Sync -Rows ($staff + $zoe) -Today '2026-10-18'   # 8 days early: nothing yet
        Get-User 'zoe.ollivierre' | Should -BeNullOrEmpty
        $null = Sync -Rows ($staff + $zoe) -Today '2026-10-19'   # 7 days: created, switched off
        (Get-User 'zoe.ollivierre').enabled | Should -BeFalse
        (Get-User 'zoe.ollivierre').groups | Should -Contain 'Finance'
        $null = Sync -Rows ($staff + $zoe) -Today '2026-10-25'
        (Get-User 'zoe.ollivierre').enabled | Should -BeFalse
        $run = Sync -Rows ($staff + $zoe) -Today '2026-10-26'
        (Get-ActionsFor $run 'zoe.ollivierre').Detail | Should -Be @('Starts today: enable the account')
        (Get-User 'zoe.ollivierre').enabled | Should -BeTrue
    }

    It 'gives a second Kevin Browne kevin.browne2, and uses preferred names' {
        $kevin = New-HrRow @{ EmployeeId = 'E1021'; FirstName = 'Kevin'; LastName = 'Browne'; Department = 'Customer Service'; JobTitle = 'Customer Service Agent'; Location = 'Bequia'; StartDate = '2026-10-19' }
        $null = Sync -Rows ($staff + $kevin) -Today '2026-10-19'
        (Get-User 'kevin.browne2').employeeId | Should -Be 'E1021'
        (Get-User 'kevin.browne2').ou | Should -Be $BequiaOu
        (Get-User 'kevin.browne').employeeId | Should -Be 'E1008'
        (Get-User 'toni.williams').givenName | Should -Be 'Toni'
    }

    It 'writes the temporary password only to the manager''s note: never the directory or the audit log' {
        $zoe = New-HrRow @{ EmployeeId = 'E1020'; FirstName = 'Zoë'; LastName = 'Ollivierre'; StartDate = '2026-10-19' }
        $run = Sync -Rows ($staff + $zoe) -Today '2026-10-19'
        $run.NewStarterNotes.Count | Should -Be 1
        $note = Get-Content $run.NewStarterNotes[0] -Raw
        $note -match 'Temporary password:\s+(\S{16})' | Should -BeTrue
        $password = $Matches[1]
        Get-Content (Join-Path $TestDrive 'directory.json') -Raw | Should -Not -BeLike "*$password*"
        Get-Content (Join-Path $TestDrive 'audit.log') -Raw | Should -Not -BeLike "*$password*"
        (Get-AuditEvents | Where-Object event -eq 'Create').detail | Should -BeLike '*Temporary password issued (not recorded here)*'
    }

    It 'creates a manager who joins the same day before their new report, and links them' {
        $boss = New-HrRow @{ EmployeeId = 'E1030'; FirstName = 'Avril'; LastName = 'Jack'; Department = 'Human Resources'; JobTitle = 'HR Director'; ManagerId = 'E1001'; StartDate = '2026-10-19' }
        $report = New-HrRow @{ EmployeeId = 'E1031'; FirstName = 'Neil'; LastName = 'Pompey'; Department = 'Human Resources'; JobTitle = 'HR Officer'; ManagerId = 'E1030'; StartDate = '2026-10-19' }
        $run = Sync -Rows ($staff + $report + $boss) -Today '2026-10-19'
        ($run.Plan.Actions | Where-Object Kind -eq 'Create').Username | Should -Be @('avril.jack', 'neil.pompey')
        (Get-User 'neil.pompey').manager | Should -Be 'avril.jack'
        (Get-User 'avril.jack').groups | Should -Contain 'People Managers'
    }

    It 'gives contractors the Contractors group and an account expiry date' {
        $shanice = New-HrRow @{ EmployeeId = 'E1024'; FirstName = 'Shanice'; LastName = "O'Garro"; Department = 'IT'; JobTitle = 'IT Support Technician'; EmploymentType = 'Contractor'; StartDate = '2026-10-20'; EndDate = '2026-12-18' }
        $null = Sync -Rows ($staff + $shanice) -Today '2026-10-20'
        $u = Get-User 'shanice.ogarro'
        $u.groups | Should -Be @('All Staff', 'Contractors', 'Helpdesk', 'IT Team', 'Kingstown Office')
        $u.accountExpires | Should -Be '2026-12-18'
    }
}

Describe 'Privileged groups' {
    BeforeEach { $staff = Initialize-Staff }

    It 'are never added automatically: they wait for approval' {
        $andre = New-HrRow @{ EmployeeId = 'E1022'; FirstName = 'Andre'; LastName = 'Cupid'; Department = 'IT'; JobTitle = 'Systems Administrator'; StartDate = '2026-10-19' }
        $run = Sync -Rows ($staff + $andre) -Today '2026-10-19'
        $pending = Get-ActionsFor $run 'andre.cupid' | Where-Object Status -eq 'NeedsApproval'
        $pending.Data.group | Should -Be @('Server Admins')
        (Get-User 'andre.cupid').groups | Should -Not -Contain 'Server Admins'
        (Get-User 'andre.cupid').groups | Should -Contain 'IT Team'
    }

    It 'held from before Turnstile are kept while they wait to be confirmed, and taken away when the job changes' {
        # Lystra's membership dates from before Turnstile (see Initialize-Staff): no approval on record.
        $run = Sync -Rows $staff -Today '2026-10-19'
        (Get-ActionsFor $run 'lystra.baptiste').Kind | Should -Be @('Confirm')
        (Get-User 'lystra.baptiste').groups | Should -Contain 'Finance Approvers'
        $null = Sync -Rows (Set-Row $staff 'E1002' @{ JobTitle = 'Accounts Assistant' }) -Today '2026-10-20'
        (Get-User 'lystra.baptiste').groups | Should -Not -Contain 'Finance Approvers'
    }
}

Describe 'Movers' {
    BeforeEach { $staff = Initialize-Staff }

    It 'swap the old department''s groups for the new one''s, and update title and manager' {
        $moved = Set-Row $staff 'E1007' @{ Department = 'Finance'; JobTitle = 'Accounts Assistant'; ManagerId = 'E1002' }
        $null = Sync -Rows $moved -Today '2026-10-19'
        $u = Get-User 'tricia.samuel'
        $u.groups | Should -Be @('All Staff', 'Finance', 'Finance Share', 'Kingstown Office')
        $u.title | Should -Be 'Accounts Assistant'
        $u.department | Should -Be 'Finance'
        $u.manager | Should -Be 'lystra.baptiste'
        (Get-AuditEvents | Where-Object event -eq 'Update').data.title.old | Should -Be 'Port Clerk'
    }

    It 'move to the new location''s OU and office group' {
        $null = Sync -Rows (Set-Row $staff 'E1013' @{ Location = 'Bequia' }) -Today '2026-10-19'
        $u = Get-User 'jerome.delves'
        $u.ou | Should -Be $BequiaOu
        $u.office | Should -Be 'Port Elizabeth, Bequia'
        $u.groups | Should -Contain 'Bequia Office'
        $u.groups | Should -Not -Contain 'Kingstown Office'
    }

    It 'keep their username when their name changes' {
        $null = Sync -Rows (Set-Row $staff 'E1003' @{ LastName = 'Matthews' }) -Today '2026-10-19'
        $u = Get-User 'keisha.john'
        $u.displayName | Should -Be 'Keisha Matthews'
        $u.surname | Should -Be 'Matthews'
        Get-User 'keisha.matthews' | Should -BeNullOrEmpty
    }
}

Describe 'Access granted by hand' {
    BeforeEach { $staff = Initialize-Staff }

    It 'is left alone and flagged when the group isn''t in the policy' {
        Set-DirectoryUser 'jerome.delves' { param($u) $u.groups += 'Ferry Terminal Project' }
        $run = Sync -Rows $staff -Today '2026-10-19'
        (Get-User 'jerome.delves').groups | Should -Contain 'Ferry Terminal Project'
        $run.Plan.Issues.Message | Should -Contain "jerome.delves is in Ferry Terminal Project, which isn't part of their job. It was added by hand, so it was left alone: please review it."
    }

    It 'is taken away when it''s a policy group their job doesn''t give them' {
        Set-DirectoryUser 'jerome.delves' { param($u) $u.groups += 'Finance Share' }
        $null = Sync -Rows $staff -Today '2026-10-19'
        (Get-User 'jerome.delves').groups | Should -Not -Contain 'Finance Share'
    }
}

Describe 'Leavers' {
    BeforeEach { $staff = Initialize-Staff }

    It 'keep their access on their last day, and lose it the next morning' {
        $leaving = Set-Row $staff 'E1006' @{ EndDate = '2026-10-19' }
        $null = Sync -Rows $leaving -Today '2026-10-19'
        (Get-User 'desmond.hazell').enabled | Should -BeTrue
        (Get-User 'desmond.hazell').accountExpires | Should -Be '2026-10-19'
        $run = Sync -Rows $leaving -Today '2026-10-20'
        (Get-ActionsFor $run 'desmond.hazell')[0].Kind | Should -Be 'Disable'   # access is cut first
        $u = Get-User 'desmond.hazell'
        $u.enabled | Should -BeFalse
        $u.groups | Should -BeNullOrEmpty
        $u.ou | Should -Be $DisabledOu
        $u.disabledOn | Should -Be '2026-10-20'
        $u.description | Should -Be 'Left 2026-10-19. Disabled by Turnstile 2026-10-20.'
    }

    It 'are deleted after 30 days, not before, even once HR drops them from the export' {
        $leaving = Set-Row $staff 'E1006' @{ EndDate = '2026-10-19' }
        $null = Sync -Rows $leaving -Today '2026-10-20'
        $gone = @($staff | Where-Object EmployeeId -ne 'E1006')
        $null = Sync -Rows $gone -Today '2026-11-18'
        Get-User 'desmond.hazell' | Should -Not -BeNullOrEmpty
        $run = Sync -Rows $gone -Today '2026-11-19'
        (Get-ReadyActions $run).Kind | Should -Be @('Delete')
        Get-User 'desmond.hazell' | Should -BeNullOrEmpty
    }

    It 'can be rehired: the same account comes back, with the new job''s access' {
        $null = Sync -Rows (Set-Row $staff 'E1006' @{ EndDate = '2026-10-19' }) -Today '2026-10-20'
        $back = Set-Row $staff 'E1006' @{ StartDate = '2026-11-02'; Department = 'Customer Service'; JobTitle = 'Customer Service Agent'; ManagerId = 'E1012' }
        $run = Sync -Rows $back -Today '2026-11-02'
        (Get-ActionsFor $run 'desmond.hazell')[0].Detail | Should -Be 'Rehired: enable the account'
        $u = Get-User 'desmond.hazell'
        $u.enabled | Should -BeTrue
        $u.disabledOn | Should -BeNullOrEmpty
        $u.description | Should -Be ''
        $u.ou | Should -Be $KingstownOu
        $u.groups | Should -Be @('All Staff', 'Bookings System', 'Customer Service', 'Kingstown Office')
    }

    It 'who never started are recorded as left, so their account is cleared away later' {
        $zoe = New-HrRow @{ EmployeeId = 'E1020'; FirstName = 'Zoë'; LastName = 'Ollivierre'; StartDate = '2026-10-26' }
        $null = Sync -Rows ($staff + $zoe) -Today '2026-10-20'
        $withdrawn = New-HrRow @{ EmployeeId = 'E1020'; FirstName = 'Zoë'; LastName = 'Ollivierre'; StartDate = '2026-10-26'; EndDate = '2026-10-26' }
        $null = Sync -Rows ($staff + $withdrawn) -Today '2026-10-27'
        (Get-User 'zoe.ollivierre').disabledOn | Should -Be '2026-10-27'
        $null = Sync -Rows ($staff + $withdrawn) -Today '2026-11-26'
        Get-User 'zoe.ollivierre' | Should -BeNullOrEmpty
    }
}

Describe 'People and rows Turnstile leaves alone' {
    BeforeEach { $staff = Initialize-Staff }

    It 'never switches back on an account someone disabled by hand' {
        Set-DirectoryUser 'jerome.delves' { param($u) $u.enabled = $false }
        $run = Sync -Rows $staff -Today '2026-10-19'
        (Get-User 'jerome.delves').enabled | Should -BeFalse
        Get-ActionsFor $run 'jerome.delves' | Should -BeNullOrEmpty
        $run.Plan.Issues.Message | Should -Contain "jerome.delves is disabled, but HR says they're working. Turnstile didn't disable it (perhaps a security lock-out), so it was left disabled: check with IT security."
    }

    It 'switches a leaver back on if HR takes the end date away' {
        $null = Sync -Rows (Set-Row $staff 'E1006' @{ EndDate = '2026-10-19' }) -Today '2026-10-20'
        $run = Sync -Rows $staff -Today '2026-10-21'
        (Get-ActionsFor $run 'desmond.hazell')[0].Detail | Should -Be 'HR no longer has an end date: enable the account again'
        (Get-User 'desmond.hazell').enabled | Should -BeTrue
    }

    It 'never touches accounts without an employee ID (service and admin accounts)' {
        $run = Sync -Rows $staff -Today '2026-10-19'
        $run.Plan.UnmanagedCount | Should -Be 2
        (Get-User 'Administrator').groups | Should -Be @('Domain Admins')
        (Get-User 'svc-backup').enabled | Should -BeTrue
        $run.Plan.Actions.Username | Should -Not -Contain 'Administrator'
    }

    It 'warns about, but doesn''t disable, someone missing from the export' {
        $run = Sync -Rows @($staff | Where-Object EmployeeId -ne 'E1013') -Today '2026-10-19'
        (Get-User 'jerome.delves').enabled | Should -BeTrue
        $run.Plan.Issues.Message | Should -Contain "jerome.delves isn't in today's HR export, so the account was left alone. Check with HR."
    }

    It 'doesn''t change someone whose row was rejected' {
        $bad = Set-Row $staff 'E1007' @{ Department = 'Finance'; StartDate = 'soon' }
        $run = Sync -Rows $bad -Today '2026-10-19'
        (Get-User 'tricia.samuel').department | Should -Be 'Port Operations'
        $run.Plan.Issues.Message | Should -Contain 'tricia.samuel was not changed, because their row in the export was rejected.'
        $run.Plan.Issues.Message | Should -Not -Contain "tricia.samuel isn't in today's HR export, so the account was left alone. Check with HR."
    }
}

Describe 'Safety stops' {
    BeforeEach { $staff = Initialize-Staff }

    It 'refuse an export that''s missing too many current staff, and change nothing' {
        $before = Get-FileHash (Join-Path $TestDrive 'directory.json')
        $run = Sync -Rows ($staff | Select-Object -First 4) -Today '2026-10-19'
        $run.Refused | Should -BeTrue
        $run.Plan.BlockedReason | Should -Be 'The HR export looks incomplete: 8 of 12 current staff aren''t in it (the limit is 20%).'
        (Get-FileHash (Join-Path $TestDrive 'directory.json')).Hash | Should -Be $before.Hash
        (Get-AuditEvents).event | Should -Be @('RunStarted', 'RunRefused')
    }

    It 'refuse to disable more than the limit in one go' {
        $glitch = foreach ($r in $staff) {
            $c = $r.PSObject.Copy(); if ($c.Department -eq 'Port Operations') { $c.EndDate = '2026-10-18' }; $c }
        $run = Sync -Rows $glitch -Today '2026-10-19'
        $run.Refused | Should -BeTrue
        $run.Plan.BlockedReason | Should -Be 'This would disable 5 accounts at once (the limit is 3). That usually means a mistake in the HR export.'
        @(Get-AllUsers | Where-Object { $_.employeeId -and -not $_.enabled }).Count | Should -Be 0
    }

    It 'can be overridden only with a reason, which is audited' {
        $glitch = foreach ($r in $staff) {
            $c = $r.PSObject.Copy(); if ($c.Department -eq 'Port Operations') { $c.EndDate = '2026-10-18' }; $c }
        { Sync -Rows $glitch -Today '2026-10-19' -Extra @{ Force = $true } } | Should -Throw '*-Force needs a -Reason*'
        $run = Sync -Rows $glitch -Today '2026-10-19' -Extra @{ Force = $true; Reason = 'Port Operations outsourced; confirmed by HR (ticket 4471)' }
        $run.Refused | Should -BeFalse
        @(Get-AllUsers | Where-Object { $_.employeeId -and -not $_.enabled }).Count | Should -Be 5
        (Get-AuditEvents | Where-Object event -eq 'SafetyOverride').detail | Should -BeLike '*Overridden: Port Operations outsourced*'
    }

    It 'refuse an export with no usable rows at all' {
        $run = Sync -Rows @(New-HrRow @{ Department = 'Nowhere' }) -Today '2026-10-19'
        $run.Plan.BlockedReason | Should -Be 'The HR export has no usable rows.'
    }
}

Describe 'Running it' {
    BeforeEach { $staff = Initialize-Staff }

    It '-WhatIf changes nothing: no directory change, no audit entries, no notes' {
        $zoe = New-HrRow @{ EmployeeId = 'E1020'; FirstName = 'Zoë'; LastName = 'Ollivierre'; StartDate = '2026-10-19' }
        $before = Get-FileHash (Join-Path $TestDrive 'directory.json')
        $run = Sync -Rows ($staff + $zoe) -Today '2026-10-19' -Extra @{ WhatIf = $true } 6>$null
        $run.DryRun | Should -BeTrue
        $run.Applied | Should -Be 0
        (Get-FileHash (Join-Path $TestDrive 'directory.json')).Hash | Should -Be $before.Hash
        Test-Path (Join-Path $TestDrive 'audit.log') | Should -BeFalse
        Test-Path (Join-Path $TestDrive 'new-starter-notes') | Should -BeFalse
    }

    It 'a second run on the same day finds nothing to do' {
        $changed = Set-Row $staff 'E1007' @{ Department = 'Finance'; JobTitle = 'Accounts Assistant' }
        (Sync -Rows $changed -Today '2026-10-19').Applied | Should -BeGreaterThan 0
        $again = Sync -Rows $changed -Today '2026-10-19'
        $again.Applied | Should -Be 0
        Get-ReadyActions $again | Should -BeNullOrEmpty
    }

    It 'when one change fails, that person''s other changes are skipped and everyone else carries on' {
        $kevin = New-HrRow @{ EmployeeId = 'E1021'; FirstName = 'Kevin'; LastName = 'Browne'; Department = 'Customer Service'; JobTitle = 'Customer Service Agent'; StartDate = '2026-10-19' }
        $zoe = New-HrRow @{ EmployeeId = 'E1020'; FirstName = 'Zoë'; LastName = 'Ollivierre'; StartDate = '2026-10-19' }
        # Every change goes to the real function, except creating kevin.browne2, which fails.
        # (Newer Pester versions don't fall back to the real function on their own.)
        $global:TurnstileRealAction = & (Get-Module Turnstile) { ${function:Invoke-TurnstileDirectoryAction} }
        Mock -ModuleName Turnstile Invoke-TurnstileDirectoryAction { & $global:TurnstileRealAction @PesterBoundParameters }
        Mock -ModuleName Turnstile Invoke-TurnstileDirectoryAction { throw 'The directory is unreachable' } -ParameterFilter { $Action.Username -eq 'kevin.browne2' -and $Action.Kind -eq 'Create' }
        $run = Sync -Rows ($staff + $kevin + $zoe) -Today '2026-10-19'
        $run.Failed | Should -Be 1 -Because ($run.Errors -join ' / ')
        $run.Skipped | Should -Be 4    # kevin's four group additions
        $run.Errors[0] | Should -BeLike 'kevin.browne2: New starter*The directory is unreachable'
        Get-User 'kevin.browne2' | Should -BeNullOrEmpty
        (Get-User 'zoe.ollivierre').enabled | Should -BeTrue
        (Get-AuditEvents | Where-Object event -eq 'Failed').target | Should -Be 'kevin.browne2'
        (Test-TurnstileAuditLog -Path (Join-Path $TestDrive 'audit.log')).Valid | Should -BeTrue
        Remove-Variable -Name TurnstileRealAction -Scope Global
    }
}
