BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $andre = New-HrRow @{ EmployeeId = 'E1022'; FirstName = 'Andre'; LastName = 'Cupid'; Department = 'IT'; JobTitle = 'Systems Administrator'; ManagerId = 'E1016'; StartDate = '2026-10-19' }
    function Report([string] $HrPath, [datetime] $Today = '2026-10-20') {
        $p = @{ DirectoryPath = (Join-Path $TestDrive 'directory.json'); PolicyPath = $PolicyPath; Today = $Today; Path = (Join-Path $TestDrive 'report.html') }
        if ($HrPath) { $p.HrPath = $HrPath }
        $file = Export-TurnstileReport @p
        Get-Content $file.FullName -Raw
    }
}

Describe 'The HTML report' {
    BeforeEach {
        $staff = Initialize-Staff
        $rows = $staff + $andre
        $null = Sync -Rows $rows -Today '2026-10-19'
        $hr = Write-Hr -Rows $rows -Name 'report.csv'
    }

    It 'has every section, with the plan, approvals waiting, findings, admin rights and activity' {
        $page = Report $hr
        foreach ($id in 'plan', 'approvals', 'review', 'privileged', 'activity') { $page | Should -Match "<section id=""$id"">" }
        $page | Should -Match 'APR-0001'
        $page | Should -Match 'Server Admins'
        $page | Should -Match 'Privileged without approval'
        $page | Should -Match '<span class="value">Intact</span>'
        $page | Should -Match 'Nothing has been edited, removed or reordered'
    }

    It 'shows a stopped run and a broken audit log plainly' {
        $log = Join-Path $TestDrive 'audit.log'
        $lines = Get-Content $log
        $lines[1] = $lines[1] -replace 'andre', 'kevin'
        Set-Content $log $lines
        $page = Report $hr
        $page | Should -Match '<span class="value">FAILS CHECK</span>'
        $page | Should -Match 'The audit log fails its check.</strong> Line 2'
        $page | Should -Match '<strong>Stopped.</strong>'
    }

    It 'treats every value as text: a job title can''t inject HTML or script' {
        Set-DirectoryUser 'jerome.delves' { param($u) $u.title = '<script>alert("x")</script><img src=x onerror=alert(1)>' }
        Set-DirectoryUser 'jerome.delves' { param($u) $u.groups += '<b>Ferry</b> & Co' }
        $page = Report $null
        $page | Should -Not -Match '<script'
        $page | Should -Not -Match '<img'
        $page | Should -Not -Match '<b>Ferry'
        $page | Should -Match '&lt;b&gt;Ferry&lt;/b&gt; &amp; Co'
    }

    It 'forbids scripts and outside requests with a Content-Security-Policy, and loads nothing from outside' {
        $page = Report $hr
        $page | Should -Match "<meta http-equiv=""Content-Security-Policy"" content=""default-src 'none'; style-src 'unsafe-inline'"
        $page | Should -Not -Match 'https?://'
        $page | Should -Not -Match '<script'
        $page | Should -Not -Match '<link'
    }

    It 'works without an HR export, and with no audit log at all' {
        Remove-Item (Join-Path $TestDrive 'audit.log')
        $page = Report $null
        $page | Should -Match 'No HR export was given'
        $page | Should -Match '<span class="value">Empty</span>'
    }

    It 'changes nothing' {
        $before = @('directory.json', 'approvals.json', 'audit.log') | ForEach-Object { (Get-FileHash (Join-Path $TestDrive $_)).Hash }
        $null = Report $hr
        $after = @('directory.json', 'approvals.json', 'audit.log') | ForEach-Object { (Get-FileHash (Join-Path $TestDrive $_)).Hash }
        $after | Should -Be $before
    }
}
