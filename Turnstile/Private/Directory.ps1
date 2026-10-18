# The directory Turnstile manages.
#
# Phase 1 has one kind: a simulated directory kept in a JSON file, shaped like Active
# Directory (usernames, OUs, groups, enabled/disabled, account expiry). Everything that
# changes it goes through Invoke-TurnstileDirectoryAction, so a real Active Directory
# connector can be added later behind the same function.

function Open-TurnstileDirectory {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Directory file not found: $Path" }
    $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($state.Contains('kind') -and $state.kind -eq 'ActiveDirectory') { return Connect-TurnstileActiveDirectory -Settings $state -Path $Path }
    if (-not $state.Contains('users') -or -not $state.Contains('groups')) { throw "$Path isn't a Turnstile directory file or an Active Directory connection file." }
    $state.users = [Collections.Generic.List[object]]::new([object[]] @($state.users))
    foreach ($u in $state.users) { $u.groups = @($u.groups) }
    [pscustomobject]@{ Kind = 'Simulated'; Path = (Resolve-Path -LiteralPath $Path).Path; State = $state }
}

function Save-TurnstileDirectory {
    # Write to a temporary file, then swap it in, so a crash can't leave half a file.
    param([Parameter(Mandatory)] $Directory)
    if ($Directory.Kind -eq 'ActiveDirectory') { return }   # every change already went straight to AD
    $json = $Directory.State | ConvertTo-Json -Depth 8
    $temp = "$($Directory.Path).tmp"
    Set-Content -LiteralPath $temp -Value $json -Encoding utf8NoBOM
    Move-Item -LiteralPath $temp -Destination $Directory.Path -Force
}

function New-TurnstileDirectoryFile {
    # An empty directory with the given groups (used by the demo and the tests).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Makes a new value; changes nothing.')]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Domain,
        [Parameter(Mandatory)][object[]] $Groups,
        [object[]] $Users = @()
    )
    $state = [ordered]@{ domain = $Domain; groups = @($Groups); users = @($Users) }
    Set-Content -LiteralPath $Path -Value ($state | ConvertTo-Json -Depth 8) -Encoding utf8NoBOM
}

function Get-TurnstileDirectoryUser {
    param([Parameter(Mandatory)] $Directory, [string] $Username)
    if ($Username) { return $Directory.State.users | Where-Object { $_.username -eq $Username } | Select-Object -First 1 }
    $Directory.State.users
}

function Get-TurnstileDirectoryGroupName {
    param([Parameter(Mandatory)] $Directory)
    @($Directory.State.groups | ForEach-Object { $_.name })
}

function Invoke-TurnstileDirectoryAction {
    <#
        Carry out one planned action. Returns nothing; throws if the directory says no.
        Kinds: Create, Enable, Update, Move, AddGroup, RemoveGroup, Disable, Delete.
    #>
    param(
        [Parameter(Mandatory)] $Directory,
        [Parameter(Mandatory)] $Action,
        [Parameter(Mandatory)][datetime] $Today,
        [securestring] $InitialPassword
    )
    if ($Directory.Kind -eq 'ActiveDirectory') {
        Invoke-TurnstileAdAction -Directory $Directory -Action $Action -Today $Today -InitialPassword $InitialPassword
        return
    }
    $users = $Directory.State.users
    $user = $users | Where-Object { $_.username -eq $Action.Username } | Select-Object -First 1
    if ($Action.Kind -ne 'Create' -and -not $user) { throw "$($Action.Username) isn't in the directory." }
    $day = Format-TurnstileDate $Today

    switch ($Action.Kind) {
        'Create' {
            if ($user) { throw "$($Action.Username) already exists." }
            if (-not $InitialPassword) { throw 'A new account needs a temporary password.' }
            $d = $Action.Data
            $users.Add([ordered]@{
                username           = $Action.Username
                employeeId         = $Action.EmployeeId
                givenName          = $d.givenName
                surname            = $d.surname
                displayName        = $d.displayName
                mail               = $d.mail
                title              = $d.title
                department         = $d.department
                office             = $d.office
                manager            = $d.manager
                ou                 = $d.ou
                enabled            = [bool] $d.enabled
                groups             = @()
                accountExpires     = $d.accountExpires
                description        = ''
                created            = $day
                disabledOn         = $null
                passwordLastSet    = $day   # the password itself is never stored here
                mustChangePassword = $true
            })
        }
        'Enable' { $user.enabled = $true; $user.disabledOn = $null }
        'Disable' {
            $user.enabled = $false
            $user.disabledOn = $day
            if ($Action.Data.description) { $user.description = $Action.Data.description }
        }
        'Update' { foreach ($k in $Action.Data.Keys) { $user[$k] = $Action.Data[$k].new } }
        'Move' { $user.ou = $Action.Data.to }
        'AddGroup' {
            if ((Get-TurnstileDirectoryGroupName $Directory) -notcontains $Action.Data.group) { throw "There's no group called $($Action.Data.group)." }
            if ($user.groups -notcontains $Action.Data.group) { $user.groups = @(@($user.groups) + $Action.Data.group | Sort-Object) }
        }
        'RemoveGroup' { $user.groups = @($user.groups | Where-Object { $_ -ne $Action.Data.group }) }
        'Delete' {
            if ($user.enabled) { throw "$($Action.Username) is still enabled; only disabled accounts are deleted." }
            [void] $users.Remove($user)
        }
        default { throw "Unknown action $($Action.Kind)." }
    }
}
