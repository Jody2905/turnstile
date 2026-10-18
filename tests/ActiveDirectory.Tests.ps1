# The Active Directory connector, against a strict fake domain (tests/fakes/ActiveDirectory).
#
# The main test runs the same weeks of HR changes through the practice directory and through
# "AD", and requires them to end up identical after every day: same accounts, OUs, groups,
# names, managers, expiry dates and leaver stamps.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot 'fakes/ActiveDirectory/ActiveDirectory.psm1') -Force
    $base = 'DC=windwardfreight,DC=example'
    $ous = "OU=Kingstown,OU=Staff,$base", "OU=Bequia,OU=Staff,$base", "OU=Disabled,$base", "OU=Service Accounts,$base"

    function New-Worlds {
        foreach ($f in 'sim', 'ad') { Remove-Item (Join-Path $TestDrive $f) -Recurse -Force -ErrorAction Ignore; New-Item -ItemType Directory (Join-Path $TestDrive $f) | Out-Null }
        $service = { param($sam, $groups) [ordered]@{ username = $sam; employeeId = $null; displayName = $sam; enabled = $true; ou = "OU=Service Accounts,$base"; groups = @($groups); description = '' } }
        $state = [ordered]@{ domain = 'windwardfreight.example'; groups = @($AllGroups | ForEach-Object { [ordered]@{ name = $_ } })
            users = @((& $service 'Administrator' @('Domain Admins')), (& $service 'svc-backup' @())) }
        Set-Content (Join-Path $TestDrive 'sim/directory.json') ($state | ConvertTo-Json -Depth 6)
        Reset-FakeAD -Base $base -OUs $ous -Groups $AllGroups
        Add-FakeADUser -Sam 'Administrator' -Ou "OU=Service Accounts,$base" -Groups 'Domain Admins'
        Add-FakeADUser -Sam 'svc-backup' -Ou "OU=Service Accounts,$base"
        Set-Content (Join-Path $TestDrive 'ad/ad.json') (@{ kind = 'ActiveDirectory'; domain = 'windwardfreight.example'; searchBase = $base } | ConvertTo-Json)
    }
    $sim = { Join-Path $TestDrive 'sim/directory.json' }
    $ad = { Join-Path $TestDrive 'ad/ad.json' }

    function SyncBoth([object[]] $Rows, [datetime] $Today) {
        $hr = Write-Hr -Rows $Rows -Name "both-$($Today.ToString('yyyyMMdd')).csv"
        Set-FakeADClock -Now $Today
        $results = foreach ($path in (& $sim), (& $ad)) {
            Invoke-TurnstileSync -HrPath $hr -DirectoryPath $path -PolicyPath $PolicyPath -Today $Today -Confirm:$false
        }
        foreach ($r in $results) { $r.Failed | Should -Be 0 -Because "$($Today.ToString('yyyy-MM-dd')): $($r.Errors -join ' / ')" }
        $results
    }

    function Get-Snapshot([string] $Path) {
        # What the planner sees, for every managed account, in a fixed order.
        $state = InModuleScope Turnstile -Parameters @{ P = $Path } { param($P) (Open-TurnstileDirectory -Path $P).State }
        $rows = foreach ($u in $state.users | Where-Object { $_.employeeId } | Sort-Object { $_.username }) {
            [ordered]@{
                username = $u.username; employeeId = $u.employeeId; enabled = [bool] $u.enabled; ou = $u.ou; groups = (@($u.groups) | Sort-Object) -join ','
                displayName = $u.displayName; givenName = $u.givenName; surname = $u.surname; title = $u.title; department = $u.department
                office = $u.office; manager = $u.manager; accountExpires = $u.accountExpires; description = "$($u.description)"; disabledOn = $u.disabledOn
            }
        }
        $rows | ForEach-Object { $_ | ConvertTo-Json -Compress }
    }

    function Assert-Same([string] $When) {
        $a = @(Get-Snapshot (& $sim)); $b = @(Get-Snapshot (& $ad))
        $b.Count | Should -Be $a.Count -Because "$When the same accounts exist"
        for ($i = 0; $i -lt $a.Count; $i++) { $b[$i] | Should -Be $a[$i] -Because "$When account $i matches" }
    }

    function Approve-Both([string] $Username, [string] $By, [datetime] $Today) {
        foreach ($path in (& $sim), (& $ad)) {
            $id = (Get-TurnstileApproval -DirectoryPath $path -Status Pending | Where-Object Username -eq $Username).Id
            $null = Approve-TurnstileAccess -DirectoryPath $path -PolicyPath $PolicyPath -Id $id -ApprovedBy $By -Ticket CHG-2001 -Today $Today -Confirm:$false
        }
    }
}

AfterAll { Remove-Module ActiveDirectory -Force -ErrorAction Ignore }

Describe 'The Active Directory connector' {
    BeforeEach {
        New-Worlds
        $staff = New-Staff
        $week = Set-Row (Set-Row (Set-Row $staff 'E1007' @{ Department = 'Finance'; JobTitle = 'Accounts Assistant'; ManagerId = 'E1002' }) 'E1003' @{ LastName = 'Matthews' }) 'E1006' @{ EndDate = '2026-10-19' }
        $week += @(
            New-HrRow @{ EmployeeId = 'E1020'; FirstName = 'Zoë'; LastName = 'Ollivierre'; ManagerId = 'E1002'; StartDate = '2026-10-26' }
            # A second Kevin Browne, in the same OU as the first: the CN must not clash.
            New-HrRow @{ EmployeeId = 'E1021'; FirstName = 'Kevin'; LastName = 'Browne'; Department = 'Customer Service'; JobTitle = 'Customer Service Agent'; ManagerId = 'E1012'; StartDate = '2026-10-19' }
            New-HrRow @{ EmployeeId = 'E1022'; FirstName = 'Andre'; LastName = 'Cupid'; Department = 'IT'; JobTitle = 'Systems Administrator'; ManagerId = 'E1016'; StartDate = '2026-10-19' }
            New-HrRow @{ EmployeeId = 'E1024'; FirstName = 'Shanice'; LastName = "O'Garro"; Department = 'IT'; JobTitle = 'IT Support Technician'; ManagerId = 'E1016'; EmploymentType = 'Contractor'; StartDate = '2026-10-20'; EndDate = '2026-12-18' }
        )
    }

    It 'ends up exactly like the practice directory, day after day' {
        $null = SyncBoth $staff '2026-10-16';  Assert-Same 'Fri 16 Oct:'
        $null = SyncBoth $week '2026-10-19';   Assert-Same 'Mon 19 Oct:'
        Approve-Both 'andre.cupid' 'dwight.robertson' '2026-10-19'
        $null = SyncBoth $week '2026-10-20';   Assert-Same 'Tue 20 Oct:'
        (Get-FakeADUserRecord 'andre.cupid').MemberOf | Should -Contain "CN=Server Admins,OU=Groups,$base"
        $null = SyncBoth $week '2026-10-26';   Assert-Same 'Mon 26 Oct:'
        $moved = Set-Row $week 'E1013' @{ Location = 'Bequia' }
        $null = SyncBoth $moved '2026-10-27';  Assert-Same 'Tue 27 Oct:'
        $null = SyncBoth $moved '2026-11-19';  Assert-Same 'Thu 19 Nov:'
        Get-FakeADUserRecord 'desmond.hazell' | Should -BeNullOrEmpty
        $zoeLeaves = Set-Row $moved 'E1020' @{ EndDate = '2026-11-19' }
        $null = SyncBoth $zoeLeaves '2026-11-20'; Assert-Same 'Fri 20 Nov:'
        $zoeBack = Set-Row $moved 'E1020' @{ StartDate = '2026-12-01'; Department = 'Customer Service'; JobTitle = 'Customer Service Agent'; ManagerId = 'E1012' }
        $runs = SyncBoth $zoeBack '2026-12-01'; Assert-Same 'Tue 1 Dec:'
        ($runs[1].Plan.Actions | Where-Object Username -eq 'zoe.ollivierre')[0].Detail | Should -Be 'Rehired: enable the account'
        $runs = SyncBoth $zoeBack '2026-12-01'
        @($runs[1].Plan.Actions | Where-Object Status -eq 'Ready').Count | Should -Be 0 -Because 'a second run against AD has nothing to do'
        (Get-FakeADUserRecord 'Administrator').MemberOf | Should -Be @("CN=Domain Admins,OU=Groups,$base")
    }

    It 'creates accounts with a SecureString password that must be changed at first sign-in' {
        $null = SyncBoth $staff '2026-10-16'
        $kevin = Get-FakeADUserRecord 'kevin.browne'
        $kevin.PasswordSet | Should -BeTrue
        $kevin.ChangePasswordAtLogon | Should -BeTrue
        $kevin.EmployeeID | Should -Be 'E1008'
        $kevin.DistinguishedName | Should -Be "CN=kevin.browne,OU=Kingstown,OU=Staff,$base"
        $kevin.Manager | Should -Be "CN=winston.ollivierre,OU=Kingstown,OU=Staff,$base"
        $kevin.EmailAddress | Should -Be 'kevin.browne@windwardfreight.example'
    }

    It 'writes an end date as AD expects it (the start of the next day), and reads it back the same' {
        $null = SyncBoth $staff '2026-10-16'
        $null = SyncBoth $week '2026-10-19'
        (Get-FakeADUserRecord 'shanice.ogarro').AccountExpirationDate | Should -Be ([datetime] '2026-12-19')
        ((Get-Snapshot (& $ad)) -match 'shanice') | Should -Match '"accountExpires":"2026-12-18"'
    }

    It 'marks a leaver so it knows it switched them off, and moves them by distinguished name' {
        $null = SyncBoth $staff '2026-10-16'
        $null = SyncBoth $week '2026-10-20'
        $desmond = Get-FakeADUserRecord 'desmond.hazell'
        $desmond.Enabled | Should -BeFalse
        $desmond.extensionAttribute15 | Should -Be 'turnstile:disabledOn=2026-10-20'
        $desmond.DistinguishedName | Should -Be "CN=desmond.hazell,OU=Disabled,$base"
        $desmond.MemberOf | Should -BeNullOrEmpty
        $desmond.Description | Should -Be 'Left 2026-10-19. Disabled by Turnstile 2026-10-20.'
    }

    It 'leaves an account someone disabled in AD by hand switched off' {
        $null = SyncBoth $staff '2026-10-16'
        Disable-ADAccount -Identity 'jerome.delves'
        Set-FakeADClock -Now '2026-10-19'
        $run = Invoke-TurnstileSync -HrPath (Write-Hr -Rows $staff -Name 'hand.csv') -DirectoryPath (& $ad) -PolicyPath $PolicyPath -Today '2026-10-19' -Confirm:$false
        (Get-FakeADUserRecord 'jerome.delves').Enabled | Should -BeFalse
        $run.Plan.Issues.Message | Should -Contain "jerome.delves is disabled, but HR says they're working. Turnstile didn't disable it (perhaps a security lock-out), so it was left disabled: check with IT security."
    }

    It 'with -WhatIf, calls nothing that changes AD' {
        $null = SyncBoth $staff '2026-10-16'
        Clear-FakeADCall
        $null = Invoke-TurnstileSync -HrPath (Write-Hr -Rows $week -Name 'whatif.csv') -DirectoryPath (& $ad) -PolicyPath $PolicyPath -Today '2026-10-20' -WhatIf 6>$null
        Get-FakeADCall | Should -BeNullOrEmpty
    }

    It 'keeps its audit log and approvals next to the connection file' {
        $null = SyncBoth $week '2026-10-19'
        Test-Path (Join-Path $TestDrive 'ad/audit.log') | Should -BeTrue
        Test-Path (Join-Path $TestDrive 'ad/approvals.json') | Should -BeTrue
        (Test-TurnstileAuditLog -Path (Join-Path $TestDrive 'ad/audit.log')).Valid | Should -BeTrue
    }
}

Describe 'Without the ActiveDirectory module' {
    It 'says how to install it' -Skip:([bool] (Get-Module -ListAvailable -Name ActiveDirectory)) {
        New-Worlds
        Remove-Module ActiveDirectory -Force
        try {
            { Get-TurnstilePlan -HrPath (Write-Hr -Rows (New-Staff) -Name 'nomodule.csv') -DirectoryPath (& $ad) -PolicyPath $PolicyPath -Today '2026-10-19' } |
                Should -Throw "*ActiveDirectory PowerShell module isn't installed*Rsat.ActiveDirectory*"
        } finally {
            Import-Module (Join-Path $PSScriptRoot 'fakes/ActiveDirectory/ActiveDirectory.psm1') -Force
        }
    }
}
