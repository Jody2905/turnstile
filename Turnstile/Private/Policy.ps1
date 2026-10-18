# The access policy (config/policy.json): who gets which groups, and the safety limits.

function Read-TurnstilePolicy {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Policy file not found: $Path" }
    try { $policy = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable }
    catch { throw "The policy file isn't valid JSON: $($_.Exception.Message)" }

    $required = 'organisation', 'domain', 'usernameMaxLength', 'prestartDays', 'leaverRetentionDays', 'safety',
        'disabledOu', 'locations', 'everyone', 'employmentTypes', 'departments', 'roles', 'privilegedGroups', 'approvals', 'review'
    $missing = $required | Where-Object { -not $policy.Contains($_) }
    if ($missing) { throw "The policy is missing: $($missing -join ', ')" }
    foreach ($role in $policy.roles) {
        if (-not $role.titleMatches -or -not $role.groups) { throw 'Every role needs titleMatches and groups.' }
        try { [void] [regex]::new($role.titleMatches) } catch { throw "Role pattern '$($role.titleMatches)' isn't a valid regular expression." }
    }
    foreach ($g in $policy.privilegedGroups) {
        if (-not $policy.approvals.groupOwners.Contains($g)) { throw "Privileged group '$g' needs an owner in approvals.groupOwners." }
    }
    foreach ($name in $policy.locations.Keys) {
        if (-not $policy.locations[$name].ou) { throw "Location '$name' needs an ou." }
    }
    $policy
}

function Get-TurnstileManagedGroup {
    # Every group the policy hands out. Only these are ever added or taken away for a role
    # change; anything else a person holds was granted by hand, so it's flagged, not removed.
    param([Parameter(Mandatory)] $Policy)
    $groups = [Collections.Generic.List[string]]::new()
    foreach ($g in $Policy.everyone) { $groups.Add($g) }
    foreach ($loc in $Policy.locations.Values) { foreach ($g in $loc.groups) { $groups.Add($g) } }
    foreach ($list in $Policy.employmentTypes.Values) { foreach ($g in $list) { $groups.Add($g) } }
    foreach ($list in $Policy.departments.Values) { foreach ($g in $list) { $groups.Add($g) } }
    foreach ($role in $Policy.roles) { foreach ($g in $role.groups) { $groups.Add($g) } }
    @($groups | Sort-Object -Unique)
}

function Get-TurnstileEntitlement {
    # The groups this person's job gives them: everyone + location + employment type +
    # department + any role whose title pattern matches.
    param([Parameter(Mandatory)] $Policy, [Parameter(Mandatory)] $Record)
    $groups = [Collections.Generic.List[string]]::new()
    foreach ($g in $Policy.everyone) { $groups.Add($g) }
    foreach ($g in $Policy.locations[$Record.Location].groups) { $groups.Add($g) }
    foreach ($g in $Policy.employmentTypes[$Record.EmploymentType]) { $groups.Add($g) }
    foreach ($g in $Policy.departments[$Record.Department]) { $groups.Add($g) }
    foreach ($role in $Policy.roles) {
        if ($Record.JobTitle -match $role.titleMatches) { foreach ($g in $role.groups) { $groups.Add($g) } }
    }
    @($groups | Sort-Object -Unique)
}

function Test-TurnstilePrivileged {
    param([Parameter(Mandatory)] $Policy, [Parameter(Mandatory)][string] $Group)
    $Policy.privilegedGroups -contains $Group
}
