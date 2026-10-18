BeforeAll { . (Join-Path $PSScriptRoot 'TestHelpers.ps1') }

Describe 'Usernames' {
    It 'makes first.last, letters only, without accents' -ForEach @(
        @{ First = 'Zoë'; Last = 'Ollivierre'; Expected = 'zoe.ollivierre' }
        @{ First = 'Shanice'; Last = "O'Garro"; Expected = 'shanice.ogarro' }
        @{ First = 'Mary-Ann'; Last = 'St. John'; Expected = 'maryann.stjohn' }
        @{ First = 'José'; Last = 'Peña'; Expected = 'jose.pena' }
    ) {
        InModuleScope Turnstile -Parameters $_ { New-TurnstileUsername -First $First -Last $Last } | Should -Be $Expected
    }

    It 'adds a number when the name is taken, ignoring case' {
        InModuleScope Turnstile {
            New-TurnstileUsername -First Kevin -Last Browne -Taken @('Kevin.Browne') | Should -Be 'kevin.browne2'
            New-TurnstileUsername -First Kevin -Last Browne -Taken @('kevin.browne', 'kevin.browne2') | Should -Be 'kevin.browne3'
        }
    }

    It 'never goes over 20 characters, even with a number on the end' {
        InModuleScope Turnstile {
            $long = New-TurnstileUsername -First 'Christopher' -Last 'Fitzgerald-Montgomery'
            $long | Should -Be 'christopher.fitzgera'
            $next = New-TurnstileUsername -First 'Christopher' -Last 'Fitzgerald-Montgomery' -Taken @($long)
            $next | Should -Be 'christopher.fitzger2'
            $next.Length | Should -BeLessOrEqual 20
        }
    }

    It 'refuses a name with no usable letters' {
        InModuleScope Turnstile { { New-TurnstileUsername -First '---' -Last 'Smith' } | Should -Throw "*Can't make a username*" }
    }
}

Describe 'Temporary passwords' {
    It 'are 16 characters with upper, lower, digit and symbol, and never repeat' {
        InModuleScope Turnstile {
            $passwords = 1..200 | ForEach-Object { New-TurnstilePassword }
            ($passwords | Sort-Object -Unique).Count | Should -Be 200
            foreach ($p in $passwords) {
                $p.Length | Should -Be 16
                $p | Should -MatchExactly '[A-Z]'
                $p | Should -MatchExactly '[a-z]'
                $p | Should -Match '[0-9]'
                $p | Should -Match '[!#$%*+\-=?@]'
                $p | Should -Not -MatchExactly '[0O1lI]'
            }
        }
    }
}

Describe 'Dates' {
    It 'only accept yyyy-MM-dd, so day and month can''t be swapped' {
        InModuleScope Turnstile {
            ConvertTo-TurnstileDate '2026-10-19' | Should -Be ([datetime] '2026-10-19')
            ConvertTo-TurnstileDate '19/10/2026' | Should -BeNullOrEmpty
            ConvertTo-TurnstileDate '10/19/2026' | Should -BeNullOrEmpty
            ConvertTo-TurnstileDate '2026-02-30' | Should -BeNullOrEmpty
            ConvertTo-TurnstileDate '' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Reading the HR export' {
    BeforeAll { $policy = InModuleScope Turnstile -Parameters @{ P = $PolicyPath } { param($P) Read-TurnstilePolicy -Path $P } }

    It 'accepts good rows' {
        $feed = Import-TurnstileHrFeed -Path (Write-Hr @((New-HrRow), (New-HrRow @{ EmployeeId = 'E2002'; FirstName = 'Zoë' }))) -Policy $policy
        $feed.Records.Count | Should -Be 2
        $feed.Issues | Should -BeNullOrEmpty
        $feed.Records[1].FirstName | Should -Be 'Zoë'
        $feed.Records[0].StartDate | Should -Be ([datetime] '2020-01-06')
    }

    It 'rejects a bad row, says why and where, and keeps the rest' -ForEach @(
        @{ Change = @{ Department = 'Marketing' }; Message = "*department 'Marketing' isn't in the policy*" }
        @{ Change = @{ Location = 'Georgetown' }; Message = "*location 'Georgetown'*" }
        @{ Change = @{ StartDate = '19/10/2026' }; Message = '*start date*should be a date like 2026-10-19*' }
        @{ Change = @{ EndDate = '2019-01-01' }; Message = '*end date is before the start date*' }
        @{ Change = @{ EmploymentType = 'Contractor' }; Message = '*contractors need an end date*' }
        @{ Change = @{ EmployeeId = '1234' }; Message = "*employee ID '1234'*" }
        @{ Change = @{ ManagerId = 'E2002' }; Message = "*can't be their own manager*" }
        @{ Change = @{ FirstName = 'R2D2' }; Message = "*FirstName 'R2D2' isn't a valid name*" }
        @{ Change = @{ LastName = '<script>' }; Message = '*isn''t a valid name*' }
        @{ Change = @{ JobTitle = '' }; Message = '*job title*' }
    ) {
        $fields = @{ EmployeeId = 'E2002' }
        foreach ($k in $Change.Keys) { $fields[$k] = $Change[$k] }
        $bad = New-HrRow $fields
        $feed = Import-TurnstileHrFeed -Path (Write-Hr @((New-HrRow), $bad)) -Policy $policy
        $feed.Records.EmployeeId | Should -Be @('E2001')
        $feed.Issues.Count | Should -Be 1
        $feed.Issues[0].Severity | Should -Be 'Error'
        $feed.Issues[0].Line | Should -Be 3
        $feed.Issues[0].Message | Should -BeLike $Message
    }

    It 'rejects both rows when the same person appears twice' {
        $feed = Import-TurnstileHrFeed -Path (Write-Hr @((New-HrRow), (New-HrRow @{ JobTitle = 'Finance Manager' }), (New-HrRow @{ EmployeeId = 'E2003' }))) -Policy $policy
        $feed.Records.EmployeeId | Should -Be @('E2003')
        @($feed.Issues | Where-Object Message -like '*appears 2 times*').Count | Should -Be 2
        $feed.RejectedIds | Should -Be @('E2001')
    }

    It 'warns (but keeps the row) when the manager isn''t in the export' {
        $feed = Import-TurnstileHrFeed -Path (Write-Hr @(New-HrRow @{ ManagerId = 'E9999' })) -Policy $policy
        $feed.Records.Count | Should -Be 1
        $feed.Issues[0].Severity | Should -Be 'Warning'
    }

    It 'refuses an export with missing columns' {
        $path = Join-Path $TestDrive 'short.csv'
        Set-Content $path "EmployeeId,FirstName`nE2001,Test"
        { Import-TurnstileHrFeed -Path $path -Policy $policy } | Should -Throw '*missing columns*LastName*'
    }
}

Describe 'The policy' {
    It 'gives each job the right groups' {
        InModuleScope Turnstile -Parameters @{ P = $PolicyPath } {
            param($P)
            $policy = Read-TurnstilePolicy -Path $P
            $groups = Get-TurnstileEntitlement -Policy $policy -Record ([pscustomobject]@{ Location = 'Bequia'; EmploymentType = 'Contractor'; Department = 'IT'; JobTitle = 'IT Support Technician' })
            $groups | Should -Be @('All Staff', 'Bequia Office', 'Contractors', 'Helpdesk', 'IT Team')
            $manager = Get-TurnstileEntitlement -Policy $policy -Record ([pscustomobject]@{ Location = 'Kingstown'; EmploymentType = 'Employee'; Department = 'Finance'; JobTitle = 'Finance Manager' })
            $manager | Should -Be @('All Staff', 'Finance', 'Finance Approvers', 'Finance Share', 'Kingstown Office', 'People Managers')
        }
    }

    It 'refuses to plan when it hands out a group the directory doesn''t have' {
        New-Directory | Out-Null
        $policy = Get-Content $PolicyPath -Raw | ConvertFrom-Json -AsHashtable
        $policy.departments.IT += 'Nonexistent Group'
        $bad = Join-Path $TestDrive 'bad-policy.json'
        $policy | ConvertTo-Json -Depth 6 | Set-Content $bad
        { Get-TurnstilePlan -HrPath (Write-Hr @(New-HrRow)) -DirectoryPath (Join-Path $TestDrive 'directory.json') -PolicyPath $bad -Today '2026-10-19' } |
            Should -Throw "*doesn't have: Nonexistent Group*"
    }
}

Describe 'The audit log' {
    BeforeEach {
        $log = Join-Path $TestDrive 'audit-test.log'
        Remove-Item $log -ErrorAction Ignore
        InModuleScope Turnstile -Parameters @{ L = $log } {
            param($L)
            foreach ($n in 1..5) { Add-TurnstileAuditEntry -Path $L -RunId 'run-test' -EventName 'Disable' -Target "user$n" -Detail "Entry $n" }
        }
        $lines = Get-Content $log
    }

    It 'checks out when untouched' {
        $r = Test-TurnstileAuditLog -Path $log
        $r.Valid | Should -BeTrue
        $r.Entries | Should -Be 5
    }

    It 'spots an edited entry' {
        $lines[2] = $lines[2] -replace 'user3', 'user9'
        Set-Content $log $lines
        $r = Test-TurnstileAuditLog -Path $log
        $r.Valid | Should -BeFalse
        $r.Problem | Should -Be 'Line 3: the entry was changed after it was written.'
    }

    It 'spots an edit even when the hash is recalculated, because the next line points at the old one' {
        $json = $lines[2].Substring(65) -replace 'user3', 'user9'
        $hash = InModuleScope Turnstile -Parameters @{ J = $json } { param($J) Get-TurnstileHash $J }
        $lines[2] = "$hash $json"
        Set-Content $log $lines
        (Test-TurnstileAuditLog -Path $log).Problem | Should -Be 'Line 4: the line before it is missing or out of order.'
    }

    It 'spots a deleted line and swapped lines' {
        Set-Content $log ($lines[0, 1, 3, 4])
        (Test-TurnstileAuditLog -Path $log).Problem | Should -Be 'Line 3: the line before it is missing or out of order.'
        Set-Content $log ($lines[0, 2, 1, 3, 4])
        (Test-TurnstileAuditLog -Path $log).Valid | Should -BeFalse
    }

    It 'spots junk added to the file' {
        Add-Content $log 'not an audit line'
        (Test-TurnstileAuditLog -Path $log).Problem | Should -Be 'Line 6: not a valid audit line.'
    }
}
