# Shared set-up for the tests: a fresh directory and HR export in Pester's TestDrive.

$script:Root = Split-Path -Parent $PSScriptRoot
$script:PolicyPath = Join-Path $Root 'config/policy.json'
Import-Module (Join-Path $Root 'Turnstile/Turnstile.psd1') -Force

$script:AllGroups = 'All Staff', 'Kingstown Office', 'Bequia Office', 'Contractors', 'Management', 'People Managers',
    'Finance', 'Finance Share', 'Finance Approvers', 'Payroll', 'Port Ops', 'Port Ops Rota',
    'Customer Service', 'Bookings System', 'IT Team', 'Helpdesk', 'Server Admins', 'HR', 'HR Confidential',
    'Domain Admins', 'Ferry Terminal Project'

$script:KingstownOu = 'OU=Kingstown,OU=Staff,DC=windwardfreight,DC=example'
$script:BequiaOu = 'OU=Bequia,OU=Staff,DC=windwardfreight,DC=example'
$script:DisabledOu = 'OU=Disabled,DC=windwardfreight,DC=example'

function New-HrRow {
    # A valid row: a Kingstown finance assistant who started years ago. Override anything.
    param([hashtable] $Change = @{})
    $row = [ordered]@{
        EmployeeId = 'E2001'; FirstName = 'Test'; LastName = 'Person'; PreferredName = ''
        Department = 'Finance'; JobTitle = 'Accounts Assistant'; Location = 'Kingstown'; ManagerId = ''
        EmploymentType = 'Employee'; StartDate = '2020-01-06'; EndDate = ''
    }
    foreach ($k in $Change.Keys) { $row[$k] = $Change[$k] }
    [pscustomobject] $row
}

function Write-Hr {
    param([Parameter(Mandatory)][object[]] $Rows, [string] $Name = 'hr.csv')
    $path = Join-Path $TestDrive $Name
    $Rows | Export-Csv -Path $path -NoTypeInformation -Encoding utf8NoBOM
    $path
}

function New-Directory {
    # The groups, plus three service accounts that must never be touched.
    param([object[]] $Users = @())
    $path = Join-Path $TestDrive 'directory.json'
    $service = @(
        [ordered]@{ username = 'Administrator'; employeeId = $null; displayName = 'Administrator'; enabled = $true; ou = 'OU=Service Accounts'; groups = @('Domain Admins'); description = 'Built-in' },
        [ordered]@{ username = 'svc-backup'; employeeId = $null; displayName = 'svc-backup'; enabled = $true; ou = 'OU=Service Accounts'; groups = @(); description = 'Backups' }
    )
    $state = [ordered]@{
        domain = 'windwardfreight.example'
        groups = @($script:AllGroups | ForEach-Object { [ordered]@{ name = $_ } })
        users  = @($service + $Users)
    }
    Set-Content -Path $path -Value ($state | ConvertTo-Json -Depth 8) -Encoding utf8NoBOM
    Remove-Item (Join-Path $TestDrive 'audit.log') -ErrorAction Ignore
    Remove-Item (Join-Path $TestDrive 'new-starter-notes') -Recurse -ErrorAction Ignore
    $path
}

function Sync {
    # Run Turnstile for one day against the test directory.
    param([Parameter(Mandatory)][object[]] $Rows, [Parameter(Mandatory)][datetime] $Today, [hashtable] $Extra = @{})
    $hr = Write-Hr -Rows $Rows -Name "hr-$($Today.ToString('yyyyMMdd')).csv"
    Invoke-TurnstileSync -HrPath $hr -DirectoryPath (Join-Path $TestDrive 'directory.json') -PolicyPath $script:PolicyPath -Today $Today -Confirm:$false @Extra
}

function Plan {
    param([Parameter(Mandatory)][object[]] $Rows, [Parameter(Mandatory)][datetime] $Today)
    $hr = Write-Hr -Rows $Rows -Name 'plan.csv'
    Get-TurnstilePlan -HrPath $hr -DirectoryPath (Join-Path $TestDrive 'directory.json') -PolicyPath $script:PolicyPath -Today $Today
}

function Get-User {
    param([string] $Username)
    $state = Get-Content (Join-Path $TestDrive 'directory.json') -Raw | ConvertFrom-Json -AsHashtable
    $state.users | Where-Object { $_.username -eq $Username } | Select-Object -First 1
}

function Get-AllUsers {
    (Get-Content (Join-Path $TestDrive 'directory.json') -Raw | ConvertFrom-Json -AsHashtable).users
}

function Get-AuditEvents {
    $path = Join-Path $TestDrive 'audit.log'
    if (-not (Test-Path $path)) { return @() }
    Get-Content $path | ForEach-Object { $_.Substring(65) | ConvertFrom-Json }
}

# A small staff, already in the directory as of Friday 16 October 2026.
function New-Staff {
    @(
        New-HrRow @{ EmployeeId = 'E1001'; FirstName = 'Garfield'; LastName = 'Providence'; Department = 'Management'; JobTitle = 'Managing Director'; StartDate = '2009-03-02' }
        New-HrRow @{ EmployeeId = 'E1002'; FirstName = 'Lystra'; LastName = 'Baptiste'; Department = 'Finance'; JobTitle = 'Finance Manager'; ManagerId = 'E1001' }
        New-HrRow @{ EmployeeId = 'E1003'; FirstName = 'Keisha'; LastName = 'John'; Department = 'Finance'; JobTitle = 'Accounts Assistant'; ManagerId = 'E1002' }
        New-HrRow @{ EmployeeId = 'E1005'; FirstName = 'Winston'; LastName = 'Ollivierre'; Department = 'Port Operations'; JobTitle = 'Port Operations Manager'; ManagerId = 'E1001' }
        New-HrRow @{ EmployeeId = 'E1006'; FirstName = 'Desmond'; LastName = 'Hazell'; Department = 'Port Operations'; JobTitle = 'Stevedore Supervisor'; ManagerId = 'E1005' }
        New-HrRow @{ EmployeeId = 'E1007'; FirstName = 'Tricia'; LastName = 'Samuel'; Department = 'Port Operations'; JobTitle = 'Port Clerk'; ManagerId = 'E1005' }
        New-HrRow @{ EmployeeId = 'E1008'; FirstName = 'Kevin'; LastName = 'Browne'; Department = 'Port Operations'; JobTitle = 'Tally Clerk'; ManagerId = 'E1005' }
        New-HrRow @{ EmployeeId = 'E1009'; FirstName = 'Junior'; LastName = 'Quashie'; Department = 'Port Operations'; JobTitle = 'Forklift Operator'; Location = 'Bequia'; ManagerId = 'E1005' }
        New-HrRow @{ EmployeeId = 'E1012'; FirstName = 'Antoinette'; PreferredName = 'Toni'; LastName = 'Williams'; Department = 'Customer Service'; JobTitle = 'Customer Service Manager'; ManagerId = 'E1001' }
        New-HrRow @{ EmployeeId = 'E1013'; FirstName = 'Jerome'; LastName = 'Delves'; Department = 'Customer Service'; JobTitle = 'Customer Service Agent'; ManagerId = 'E1012' }
        New-HrRow @{ EmployeeId = 'E1016'; FirstName = 'Dwight'; LastName = 'Robertson'; Department = 'IT'; JobTitle = 'IT Manager'; ManagerId = 'E1001' }
        New-HrRow @{ EmployeeId = 'E1018'; FirstName = 'Carla'; LastName = 'Bowman'; Department = 'Human Resources'; JobTitle = 'HR Manager'; ManagerId = 'E1001' }
    )
}

function Initialize-Staff {
    # Directory + staff, set up by a Friday run, so tests start from a realistic place.
    New-Directory | Out-Null
    $staff = New-Staff
    $null = Sync -Rows $staff -Today '2026-10-16'
    # Approved before Turnstile: Lystra's privileged Finance Approvers membership.
    Set-DirectoryUser 'lystra.baptiste' { param($u) $u.groups = @(@($u.groups) + 'Finance Approvers' | Sort-Object) }
    Remove-Item (Join-Path $TestDrive 'audit.log') -ErrorAction Ignore
    Remove-Item (Join-Path $TestDrive 'new-starter-notes') -Recurse -ErrorAction Ignore
    $staff
}

function Set-DirectoryUser {
    # Change an account directly, as an admin might by hand.
    param([string] $Username, [scriptblock] $Change)
    $path = Join-Path $TestDrive 'directory.json'
    $state = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
    & $Change ($state.users | Where-Object { $_.username -eq $Username })
    Set-Content -Path $path -Value ($state | ConvertTo-Json -Depth 8) -Encoding utf8NoBOM
}

function Set-Row {
    # A copy of the staff list with one person's row changed.
    param([object[]] $Rows, [string] $EmployeeId, [hashtable] $Change)
    foreach ($r in $Rows) {
        $copy = $r.PSObject.Copy()
        if ($copy.EmployeeId -eq $EmployeeId) { foreach ($k in $Change.Keys) { $copy.$k = $Change[$k] } }
        $copy
    }
}
