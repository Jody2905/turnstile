# A fake ActiveDirectory module for the tests: the cmdlets Turnstile uses, with the same names
# and parameters, keeping a small domain in memory.
#
# It's deliberately strict, refusing what a real domain controller refuses, so a careless
# connector fails here first:
#   - a sAMAccountName that's taken, or longer than 20 characters
#   - two objects with the same name (CN) in one OU
#   - an OU, group, user or manager that doesn't exist
#   - adding someone to a group they're already in, or removing them from one they aren't
#   - a password that isn't a SecureString, or is too simple
#   - Move-ADObject given a username instead of a distinguished name
#
# Only the Turnstile tests load it. It never talks to a real domain.

$script:Base = ''
$script:Ous = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:Groups = [ordered]@{}
$script:Users = [Collections.Generic.List[object]]::new()
$script:Calls = [Collections.Generic.List[string]]::new()
$script:Now = [datetime] '2026-10-16'

function Reset-FakeAD {
    param([string] $Base, [string[]] $OUs, [string[]] $Groups)
    $script:Base = $Base
    $script:Ous.Clear(); foreach ($o in $OUs) { [void] $script:Ous.Add($o) }
    $script:Groups = [ordered]@{}
    foreach ($g in $Groups) { $script:Groups[$g] = "CN=$g,OU=Groups,$Base" }
    $script:Users.Clear()
    $script:Calls.Clear()
}
function Set-FakeADClock { param([datetime] $Now) $script:Now = $Now }
function Get-FakeADCall { @($script:Calls) }
function Clear-FakeADCall { $script:Calls.Clear() }
function Get-FakeADUserRecord { param([string] $Sam) $script:Users | Where-Object { $_.SamAccountName -eq $Sam } }

function Add-FakeADUser {
    # Seed an account directly (service accounts and the like).
    param([string] $Sam, [string] $Ou, [string[]] $Groups = @(), [string] $Description = '')
    $script:Users.Add(@{
        SamAccountName = $Sam; Name = $Sam; DistinguishedName = "CN=$Sam,$Ou"; Enabled = $true; EmployeeID = $null
        GivenName = $null; Surname = $null; DisplayName = $Sam; EmailAddress = $null; Title = $null; Department = $null; Office = $null
        Manager = $null; MemberOf = [Collections.Generic.List[string]]::new([string[]] @($Groups | ForEach-Object { $script:Groups[$_] }))
        Description = $Description; whenCreated = $script:Now; AccountExpirationDate = $null; extensionAttribute15 = $null
        ChangePasswordAtLogon = $false
    })
}

function Find-FakeUser([string] $Identity) {
    $u = $script:Users | Where-Object { $_.SamAccountName -eq $Identity -or $_.DistinguishedName -eq $Identity } | Select-Object -First 1
    if (-not $u) { throw "Cannot find an object with identity: '$Identity' under: '$script:Base'." }
    $u
}
function Find-FakeGroupDn([string] $Identity) {
    if ($script:Groups.Contains($Identity)) { return $script:Groups[$Identity] }
    foreach ($k in $script:Groups.Keys) { if ($script:Groups[$k] -eq $Identity) { return $script:Groups[$k] } }
    throw "Cannot find an object with identity: '$Identity' under: '$script:Base'."
}
function Test-FakeDnFree([string] $Dn) {
    if ($script:Users | Where-Object { $_.DistinguishedName -eq $Dn }) { throw 'An attempt was made to add an object to the directory with a name that is already in use' }
}
function ConvertTo-FakeView($u) {
    $view = [ordered]@{}
    foreach ($k in $u.Keys) { $view[$k] = $u[$k] }
    $view.MemberOf = @($u.MemberOf)
    [pscustomobject] $view
}

function Get-ADUser {
    [CmdletBinding()]
    param([string] $Filter, [string] $SearchBase, [string[]] $Properties, [string] $Identity, [string] $Server)
    if ($Identity) { return ConvertTo-FakeView (Find-FakeUser $Identity) }
    if ($Filter -ne '*') { throw 'The fake only supports -Filter *.' }
    $script:Users | Where-Object { -not $SearchBase -or $_.DistinguishedName.EndsWith($SearchBase, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { ConvertTo-FakeView $_ }
}

function Get-ADGroup {
    [CmdletBinding()]
    param([string] $Filter, [string] $SearchBase, [string] $Identity, [string] $Server)
    foreach ($k in $script:Groups.Keys) { [pscustomobject]@{ Name = $k; DistinguishedName = $script:Groups[$k] } }
}

function New-ADUser {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Name, [string] $SamAccountName, [string] $UserPrincipalName, [string] $EmailAddress,
        [string] $GivenName, [string] $Surname, [string] $DisplayName, [string] $Title, [string] $Department, [string] $Office,
        [string] $EmployeeID, [string] $Path, [bool] $Enabled, [securestring] $AccountPassword, [bool] $ChangePasswordAtLogon,
        [datetime] $AccountExpirationDate, [string] $Manager, [string] $Server
    )
    $script:Calls.Add("New-ADUser $SamAccountName")
    if (-not $script:Ous.Contains($Path)) { throw "The OU '$Path' does not exist." }
    if ($SamAccountName.Length -gt 20) { throw "sAMAccountName '$SamAccountName' is longer than 20 characters." }
    if ($script:Users | Where-Object { $_.SamAccountName -eq $SamAccountName }) { throw "The account '$SamAccountName' already exists." }
    $dn = "CN=$Name,$Path"
    Test-FakeDnFree $dn
    if ($Enabled -or $AccountPassword) {
        if (-not $AccountPassword) { throw 'The password does not meet the length, complexity, or history requirement of the domain.' }
        $plain = [Net.NetworkCredential]::new('', $AccountPassword).Password
        if ($plain.Length -lt 12 -or $plain -cnotmatch '[A-Z]' -or $plain -cnotmatch '[a-z]' -or $plain -notmatch '[0-9]') {
            throw 'The password does not meet the length, complexity, or history requirement of the domain.'
        }
    }
    if ($Manager) { $null = Find-FakeUser $Manager }
    $script:Users.Add(@{
        SamAccountName = $SamAccountName; Name = $Name; DistinguishedName = $dn; Enabled = $Enabled; EmployeeID = $EmployeeID
        GivenName = $GivenName; Surname = $Surname; DisplayName = $DisplayName; EmailAddress = $EmailAddress; Title = $Title
        Department = $Department; Office = $Office; Manager = $(if ($Manager) { (Find-FakeUser $Manager).DistinguishedName } else { $null })
        MemberOf = [Collections.Generic.List[string]]::new(); Description = $null; whenCreated = $script:Now
        AccountExpirationDate = $(if ($PSBoundParameters.ContainsKey('AccountExpirationDate')) { $AccountExpirationDate } else { $null })
        extensionAttribute15 = $null; ChangePasswordAtLogon = $ChangePasswordAtLogon; PasswordSet = [bool] $AccountPassword
    })
}

function Set-ADUser {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Identity, [string] $GivenName, [string] $Surname, [string] $DisplayName, [string] $Title,
        [string] $Department, [string] $Office, [string] $Description, [string] $Manager, [string[]] $Clear, [hashtable] $Replace, [string] $Server
    )
    $u = Find-FakeUser $Identity
    $script:Calls.Add("Set-ADUser $($u.SamAccountName)")
    foreach ($p in 'GivenName', 'Surname', 'DisplayName', 'Title', 'Department', 'Office', 'Description') {
        if ($PSBoundParameters.ContainsKey($p)) { $u[$p] = $PSBoundParameters[$p] }
    }
    if ($PSBoundParameters.ContainsKey('Manager')) { $u.Manager = (Find-FakeUser $Manager).DistinguishedName }
    $ldap = @{ givenName = 'GivenName'; sn = 'Surname'; displayName = 'DisplayName'; title = 'Title'; department = 'Department'
        physicalDeliveryOfficeName = 'Office'; description = 'Description'; manager = 'Manager'; extensionAttribute15 = 'extensionAttribute15' }
    foreach ($a in $Clear) {
        if (-not $ldap.ContainsKey($a)) { throw "The fake doesn't know the attribute '$a'." }
        $u[$ldap[$a]] = $null
    }
    if ($Replace) { foreach ($k in $Replace.Keys) { $u[$ldap[$k]] = $Replace[$k] } }
}

function Enable-ADAccount { [CmdletBinding(SupportsShouldProcess)] param([Parameter(Mandatory)][string] $Identity, [string] $Server)
    $u = Find-FakeUser $Identity; $script:Calls.Add("Enable-ADAccount $($u.SamAccountName)"); $u.Enabled = $true }
function Disable-ADAccount { [CmdletBinding(SupportsShouldProcess)] param([Parameter(Mandatory)][string] $Identity, [string] $Server)
    $u = Find-FakeUser $Identity; $script:Calls.Add("Disable-ADAccount $($u.SamAccountName)"); $u.Enabled = $false }

function Move-ADObject {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Identity, [Parameter(Mandatory)][string] $TargetPath, [string] $Server)
    if ($Identity -notmatch '^CN=') { throw "Move-ADObject needs a distinguished name or GUID, not '$Identity'." }
    $u = Find-FakeUser $Identity
    $script:Calls.Add("Move-ADObject $($u.SamAccountName)")
    if (-not $script:Ous.Contains($TargetPath)) { throw "The OU '$TargetPath' does not exist." }
    $dn = "CN=$($u.Name),$TargetPath"
    Test-FakeDnFree $dn
    $old = $u.DistinguishedName
    $u.DistinguishedName = $dn
    foreach ($other in $script:Users) { if ($other.Manager -eq $old) { $other.Manager = $dn } }
}

function Add-ADGroupMember {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Identity, [Parameter(Mandatory)][string[]] $Members, [string] $Server)
    $g = Find-FakeGroupDn $Identity
    foreach ($m in $Members) {
        $u = Find-FakeUser $m
        $script:Calls.Add("Add-ADGroupMember $Identity $($u.SamAccountName)")
        if ($u.MemberOf.Contains($g)) { throw 'The specified account name is already a member of the group.' }
        $u.MemberOf.Add($g)
    }
}

function Remove-ADGroupMember {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Identity, [Parameter(Mandatory)][string[]] $Members, [string] $Server)
    $g = Find-FakeGroupDn $Identity
    foreach ($m in $Members) {
        $u = Find-FakeUser $m
        $script:Calls.Add("Remove-ADGroupMember $Identity $($u.SamAccountName)")
        if (-not $u.MemberOf.Remove($g)) { throw 'The specified account name is not a member of the group.' }
    }
}

function Remove-ADUser {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Identity, [string] $Server)
    $u = Find-FakeUser $Identity
    $script:Calls.Add("Remove-ADUser $($u.SamAccountName)")
    [void] $script:Users.Remove($u)
}

function Set-ADAccountExpiration {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Identity, [Parameter(Mandatory)][datetime] $DateTime, [string] $Server)
    $u = Find-FakeUser $Identity; $script:Calls.Add("Set-ADAccountExpiration $($u.SamAccountName)"); $u.AccountExpirationDate = $DateTime
}
function Clear-ADAccountExpiration {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Identity, [string] $Server)
    $u = Find-FakeUser $Identity; $script:Calls.Add("Clear-ADAccountExpiration $($u.SamAccountName)"); $u.AccountExpirationDate = $null
}

Export-ModuleMember -Function *-AD*, *-FakeAD*
