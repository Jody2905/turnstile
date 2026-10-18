# The Active Directory connector.
#
# Point any Turnstile command's -DirectoryPath at a small connection file instead of a practice
# directory, and it works on a real domain:
#
#   { "kind": "ActiveDirectory", "domain": "windwardfreight.example",
#     "searchBase": "DC=windwardfreight,DC=example", "server": "dc01.windwardfreight.example" }
#
# The audit log, approvals and new-starter notes are kept in the same folder as that file.
#
# Reading: one snapshot of the users and groups under searchBase, turned into exactly the shape
# the practice directory uses, so the planner can't tell the two apart.
# Writing: each planned action becomes the matching ActiveDirectory cmdlet. -WhatIf stops
# before any of them is called.
#
# How Turnstile's fields map onto AD:
#   username        sAMAccountName (also the object's name, so the CN never clashes when two
#                   people share a name)
#   employeeId      employeeID; accounts without one are never touched
#   accountExpires  AD stores the moment the account stops working, which is the start of the
#                   day after the last working day, so 2026-12-18 is written as 2026-12-19 00:00
#   disabledOn      extensionAttribute15 = "turnstile:disabledOn=2026-10-20", so Turnstile can
#                   tell accounts it switched off from accounts a person switched off
#   ou              the parent of the account's distinguished name

$script:AdProperties = 'EmployeeID', 'GivenName', 'Surname', 'DisplayName', 'EmailAddress', 'Title', 'Department', 'Office',
    'Manager', 'MemberOf', 'Description', 'whenCreated', 'AccountExpirationDate', 'extensionAttribute15', 'Enabled'
$script:DisabledStamp = 'turnstile:disabledOn='
$script:AdAttribute = @{ givenName = 'givenName'; surname = 'sn'; displayName = 'displayName'; title = 'title'; department = 'department'; office = 'physicalDeliveryOfficeName'; description = 'description'; manager = 'manager' }
$script:AdParameter = @{ givenName = 'GivenName'; surname = 'Surname'; displayName = 'DisplayName'; title = 'Title'; department = 'Department'; office = 'Office'; description = 'Description' }

function Get-TurnstileParentDn {
    # "CN=kevin.browne,OU=Kingstown,OU=Staff,DC=..." -> "OU=Kingstown,OU=Staff,DC=..." (escaped commas allowed in the CN)
    param([Parameter(Mandatory)][string] $DistinguishedName)
    if ($DistinguishedName -match '^(?:[^,\\]|\\.)+,(.+)$') { return $Matches[1] }
    throw "Can't read the distinguished name '$DistinguishedName'."
}

function Connect-TurnstileActiveDirectory {
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)][string] $Path)
    if (-not $Settings['searchBase']) { throw "$Path needs a searchBase, for example DC=windwardfreight,DC=example." }
    if (-not (Get-Module -Name ActiveDirectory)) {
        try { Import-Module ActiveDirectory -ErrorAction Stop }
        catch {
            throw "The ActiveDirectory PowerShell module isn't installed, so Turnstile can't reach the domain. On Windows 10/11, install RSAT: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0"
        }
    }
    $server = @{}
    if ($Settings['server']) { $server.Server = $Settings['server'] }

    $groups = @(ActiveDirectory\Get-ADGroup -Filter * -SearchBase $Settings.searchBase @server)
    $groupByDn = @{}
    foreach ($g in $groups) { $groupByDn[$g.DistinguishedName] = $g.Name }
    $adUsers = @(ActiveDirectory\Get-ADUser -Filter * -SearchBase $Settings.searchBase -Properties $script:AdProperties @server)
    $samByDn = @{}
    foreach ($u in $adUsers) { $samByDn[$u.DistinguishedName] = $u.SamAccountName }

    $users = [Collections.Generic.List[object]]::new()
    foreach ($u in $adUsers) {
        $stamp = "$($u.extensionAttribute15)"
        $users.Add([ordered]@{
            username       = $u.SamAccountName
            employeeId     = $(if ($u.EmployeeID) { "$($u.EmployeeID)" } else { $null })
            givenName      = $u.GivenName
            surname        = $u.Surname
            displayName    = $u.DisplayName
            mail           = $u.EmailAddress
            title          = $u.Title
            department     = $u.Department
            office         = $u.Office
            manager        = $(if ($u.Manager) { $samByDn[$u.Manager] } else { $null })
            ou             = Get-TurnstileParentDn $u.DistinguishedName
            enabled        = [bool] $u.Enabled
            groups         = @(@($u.MemberOf) | Where-Object { $groupByDn.ContainsKey($_) } | ForEach-Object { $groupByDn[$_] } | Sort-Object)
            accountExpires = $(if ($u.AccountExpirationDate) { Format-TurnstileDate ([datetime] $u.AccountExpirationDate).Date.AddDays(-1) } else { $null })
            description    = $(if ($u.Description) { "$($u.Description)" } else { '' })
            created        = $(if ($u.whenCreated) { Format-TurnstileDate ([datetime] $u.whenCreated) } else { $null })
            disabledOn     = $(if ($stamp.StartsWith($script:DisabledStamp)) { $stamp.Substring($script:DisabledStamp.Length) } else { $null })
        })
    }
    $state = [ordered]@{ domain = $Settings['domain']; groups = @($groups | ForEach-Object { [ordered]@{ name = $_.Name } }); users = $users }
    [pscustomobject]@{ Kind = 'ActiveDirectory'; Path = (Resolve-Path -LiteralPath $Path).Path; State = $state; Server = $server }
}

function Invoke-TurnstileAdAction {
    param([Parameter(Mandatory)] $Directory, [Parameter(Mandatory)] $Action, [Parameter(Mandatory)][datetime] $Today, [securestring] $InitialPassword)
    $s = $Directory.Server
    $sam = $Action.Username
    $d = $Action.Data
    $dnOf = { param($username) (ActiveDirectory\Get-ADUser -Identity $username @s).DistinguishedName }
    $expiry = { param($day) (ConvertTo-TurnstileDate $day).AddDays(1) }

    switch ($Action.Kind) {
        'Create' {
            if (-not $InitialPassword) { throw 'A new account needs a temporary password.' }
            $p = @{
                Name = $sam; SamAccountName = $sam; UserPrincipalName = $d.mail; EmailAddress = $d.mail
                GivenName = $d.givenName; Surname = $d.surname; DisplayName = $d.displayName
                Title = $d.title; Department = $d.department; Office = $d.office; EmployeeID = $Action.EmployeeId
                Path = $d.ou; Enabled = [bool] $d.enabled; AccountPassword = $InitialPassword; ChangePasswordAtLogon = $true
            }
            if ($d['accountExpires']) { $p.AccountExpirationDate = & $expiry $d.accountExpires }
            if ($d['manager']) { $p.Manager = & $dnOf $d.manager }
            ActiveDirectory\New-ADUser @p @s
        }
        'Enable' {
            ActiveDirectory\Enable-ADAccount -Identity $sam @s
            ActiveDirectory\Set-ADUser -Identity $sam -Clear extensionAttribute15 @s
        }
        'Disable' {
            ActiveDirectory\Disable-ADAccount -Identity $sam @s
            ActiveDirectory\Set-ADUser -Identity $sam -Description $d.description -Replace @{ extensionAttribute15 = "$($script:DisabledStamp)$(Format-TurnstileDate $Today)" } @s
        }
        'Update' {
            $set = @{}
            $clear = [Collections.Generic.List[string]]::new()
            foreach ($k in $d.Keys) {
                $new = $d[$k].new
                if ($k -eq 'accountExpires') {
                    if ($new) { ActiveDirectory\Set-ADAccountExpiration -Identity $sam -DateTime (& $expiry $new) @s }
                    else { ActiveDirectory\Clear-ADAccountExpiration -Identity $sam @s }
                } elseif ($k -eq 'manager') {
                    if ($new) { $set.Manager = & $dnOf $new } else { $clear.Add('manager') }
                } elseif (Test-TurnstileBlank $new) {
                    $clear.Add($script:AdAttribute[$k])
                } else {
                    $set[$script:AdParameter[$k]] = $new
                }
            }
            if ($clear.Count) { $set.Clear = [string[]] $clear }
            if ($set.Count) { ActiveDirectory\Set-ADUser -Identity $sam @set @s }
        }
        'Move' { ActiveDirectory\Move-ADObject -Identity (& $dnOf $sam) -TargetPath $d.to @s }
        'AddGroup' { ActiveDirectory\Add-ADGroupMember -Identity $d.group -Members $sam @s }
        'RemoveGroup' { ActiveDirectory\Remove-ADGroupMember -Identity $d.group -Members $sam -Confirm:$false @s }
        'Delete' { ActiveDirectory\Remove-ADUser -Identity $sam -Confirm:$false @s }
        default { throw "Unknown action $($Action.Kind)." }
    }
}
