# Random weeks of HR changes, checked against rules that must always hold.
#
# Each seed builds a company, then for three weeks makes random changes every day: people
# join (some days ahead), move department or island, change name, leave, get rehired, and
# contractors come and go. After every run the directory must obey every rule below, and a
# second run must find nothing left to do. The seed is in the test name, so any failure can
# be replayed exactly.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $policy = Get-Content $PolicyPath -Raw | ConvertFrom-Json -AsHashtable

    $firsts = 'Akeem', 'Zoë', 'Kemar', 'Shellon', 'Andre', 'Nadia', 'José', 'Petra', 'Dwayne', 'Keisha', 'Marlon', 'Shanice', 'Kevin', 'Toni', 'Mary-Ann'
    $lasts = 'Browne', 'Ollivierre', "O'Garro", 'Quashie', 'Delves', 'John', 'Peña', 'Cain', 'Hazell', 'Samuel', 'St. Hill', 'Providence', 'Fitzgerald-Montgomery'
    $titles = @{
        'Management'       = @('Managing Director', 'Operations Director')
        'Finance'          = @('Accounts Assistant', 'Finance Manager', 'Payroll Officer', 'Credit Controller')
        'Port Operations'  = @('Tally Clerk', 'Port Clerk', 'Forklift Operator', 'Stevedore Supervisor')
        'Customer Service' = @('Customer Service Agent', 'Bookings Coordinator', 'Customer Service Manager')
        'IT'               = @('IT Support Technician', 'Systems Administrator', 'IT Manager')
        'Human Resources'  = @('HR Officer', 'HR Manager')
    }
    $departments = @($titles.Keys | Sort-Object)
    $pick = { param($list) $list = @($list); if ($list.Count) { $list[(Get-Random -Maximum $list.Count)] } }
    $day = { param([datetime] $d) $d.ToString('yyyy-MM-dd') }

    function New-RandomPerson([int] $Id, [datetime] $Start) {
        $dept = & $pick $departments
        $contract = (Get-Random -Maximum 6) -eq 0
        New-HrRow @{
            EmployeeId = "E$Id"; FirstName = (& $pick $firsts); LastName = (& $pick $lasts)
            Department = $dept; JobTitle = (& $pick $titles[$dept]); Location = (& $pick @('Kingstown', 'Kingstown', 'Bequia'))
            EmploymentType = $(if ($contract) { 'Contractor' } else { 'Employee' })
            StartDate = (& $day $Start); EndDate = $(if ($contract) { & $day $Start.AddDays(40 + (Get-Random -Maximum 60)) } else { '' })
        }
    }

    function Assert-DirectoryRules([object[]] $Rows, [datetime] $Today, [string] $Context) {
        $users = @(Get-AllUsers)
        $byId = @{}; foreach ($r in $Rows) { $byId[$r.EmployeeId] = $r }
        $names = @($users | ForEach-Object { $_.username.ToLowerInvariant() })
        ($names | Sort-Object -Unique).Count | Should -Be $names.Count -Because "$Context usernames must be unique"
        (Get-User 'Administrator').groups | Should -Be @('Domain Admins') -Because "$Context service accounts are never touched"
        (Get-User 'svc-backup').enabled | Should -BeTrue -Because "$Context service accounts are never touched"
        foreach ($u in $users | Where-Object { $_.employeeId }) {
            $who = "$Context $($u.username)"
            $u.username | Should -MatchExactly '^[a-z]+\.[a-z]+\d*$' -Because "$who usernames are first.last"
            $u.username.Length | Should -BeLessOrEqual 20 -Because "$who fits sAMAccountName"
            foreach ($g in $u.groups) { $policy.privilegedGroups | Should -Not -Contain $g -Because "$who never gets a privileged group without approval" }
            $r = $byId[$u.employeeId]
            if (-not $r) { continue }
            $left = $r.EndDate -and $Today -gt [datetime] $r.EndDate
            $started = $Today -ge [datetime] $r.StartDate
            if ($left) {
                $u.enabled | Should -BeFalse -Because "$who has left"
                $u.groups | Should -BeNullOrEmpty -Because "$who has left"
                $u.ou | Should -Be $DisabledOu -Because "$who has left"
            } else {
                $u.enabled | Should -Be $started -Because "$who is enabled exactly when they've started"
                $expected = InModuleScope Turnstile -Parameters @{ P = $policy; R = $r } {
                    param($P, $R)
                    $record = [pscustomobject]@{ Location = $R.Location; EmploymentType = $R.EmploymentType; Department = $R.Department; JobTitle = $R.JobTitle }
                    @(Get-TurnstileEntitlement -Policy $P -Record $record | Where-Object { $P.privilegedGroups -notcontains $_ })
                }
                @($u.groups) | Should -Be $expected -Because "$who has exactly their job's groups"
                $u.title | Should -Be $r.JobTitle -Because "$who title follows HR"
                $u.ou | Should -Be $policy.locations[$r.Location].ou -Because "$who OU follows their location"
            }
        }
        (Test-TurnstileAuditLog -Path (Join-Path $TestDrive 'audit.log')).Valid | Should -BeTrue -Because "$Context the audit log stays intact"
    }
}

Describe 'Three random weeks' {
    It 'keeps every rule, every day (seed <Seed>)' -ForEach @(@{ Seed = 11 }, @{ Seed = 2026 }, @{ Seed = 784 }) {
        $null = Get-Random -SetSeed $Seed
        New-Directory | Out-Null
        $today = [datetime] '2026-10-19'
        $nextId = 3000
        $rows = [Collections.Generic.List[object]]::new()
        foreach ($n in 1..15) { $rows.Add((New-RandomPerson $nextId $today.AddDays(-400))); $nextId++ }
        $runs = 0

        foreach ($d in 0..20) {
            $today = ([datetime] '2026-10-19').AddDays($d)
            $current = @($rows | Where-Object { -not $_.EndDate -or [datetime] $_.EndDate -ge $today })
            switch (Get-Random -Maximum 7) {
                0 { $rows.Add((New-RandomPerson $nextId $today.AddDays((Get-Random -Minimum -1 -Maximum 10)))); $nextId++ }
                1 {   # moves department
                    $p = & $pick $current; if ($p) { $p.Department = & $pick $departments; $p.JobTitle = & $pick $titles[$p.Department] } }
                2 { $p = & $pick $current; if ($p) { $p.Location = $(if ($p.Location -eq 'Kingstown') { 'Bequia' } else { 'Kingstown' }) } }
                3 { $p = & $pick $current; if ($p) { $p.LastName = & $pick $lasts } }
                4 {   # leaves, now or soon
                    $p = & $pick @($current | Where-Object EmploymentType -eq 'Employee')
                    if ($p) { $p.EndDate = & $day $today.AddDays((Get-Random -Minimum -1 -Maximum 4)); if ([datetime] $p.EndDate -lt [datetime] $p.StartDate) { $p.EndDate = $p.StartDate } } }
                5 {   # someone who left is rehired
                    $p = & $pick @($rows | Where-Object { $_.EndDate -and $_.EmploymentType -eq 'Employee' -and [datetime] $_.EndDate -lt $today.AddDays(-1) })
                    if ($p) { $p.StartDate = & $day $today; $p.EndDate = '' } }
                6 {   # HR drops long-gone leavers from the export
                    $gone = @($rows | Where-Object { $_.EndDate -and [datetime] $_.EndDate -lt $today.AddDays(-10) })
                    foreach ($g in $gone) { [void] $rows.Remove($g) } }
            }
            $run = Sync -Rows @($rows) -Today $today
            if ($run.Refused) { continue }   # a safety stop is allowed; the rules are checked on the next run
            $runs++
            $run.Failed | Should -Be 0 -Because "seed $Seed day $d"
            Assert-DirectoryRules -Rows @($rows) -Today $today -Context "seed $Seed day ${d}:"
            $again = Sync -Rows @($rows) -Today $today
            $again.Applied | Should -Be 0 -Because "seed $Seed day ${d}: a second run has nothing left to do"
        }
        $runs | Should -BeGreaterThan 15
    }
}
