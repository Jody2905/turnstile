# Reading HR's daily export. One bad row is rejected and reported; the rest still count.

$script:HrColumns = 'EmployeeId', 'FirstName', 'LastName', 'PreferredName', 'Department', 'JobTitle',
    'Location', 'ManagerId', 'EmploymentType', 'StartDate', 'EndDate'

# Letters (any language), spaces, hyphens, apostrophes and full stops. No digits or symbols,
# which also keeps anything like <script> out of the reports built from these names.
$script:NamePattern = "^\p{L}[\p{L}\p{M} '\-\.]{0,49}$"
$script:TitlePattern = "^[\p{L}\p{N}][\p{L}\p{M}\p{N} &/,'\.\-()]{0,79}$"

function Import-TurnstileHrFeed {
    <#
    .SYNOPSIS
        Read and check an HR export (CSV).
    .DESCRIPTION
        Returns the valid records, plus an issue for every problem found. A row with any error
        is left out completely, so nobody gets half-applied changes from a bad row.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)] $Policy
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "HR export not found: $Path" }
    $header = (Get-Content -LiteralPath $Path -TotalCount 1)
    if (-not $header) { throw "The HR export is empty: $Path" }
    $columns = $header.Split(',') | ForEach-Object { $_.Trim().Trim('"') }
    $missing = $script:HrColumns | Where-Object { $columns -notcontains $_ }
    if ($missing) { throw "The HR export is missing columns: $($missing -join ', ')" }

    $rows = @(Import-Csv -LiteralPath $Path)
    $records = [Collections.Generic.List[object]]::new()
    $issues = [Collections.Generic.List[object]]::new()
    $rejected = [Collections.Generic.HashSet[string]]::new()
    $issue = { param($severity, $line, $id, $message)
        $issues.Add([pscustomobject]@{ Severity = $severity; Line = $line; EmployeeId = $id; Message = $message }) }

    for ($i = 0; $i -lt $rows.Count; $i++) {
        $row = $rows[$i]
        $line = $i + 2   # line 1 is the header
        $v = @{}
        foreach ($c in $script:HrColumns) { $v[$c] = "$($row.$c)".Trim() }
        $errors = [Collections.Generic.List[string]]::new()

        if ($v.EmployeeId -notmatch '^E\d{4,6}$') { $errors.Add("employee ID '$($v.EmployeeId)' should look like E1234") }
        foreach ($c in 'FirstName', 'LastName') {
            if ($v[$c] -notmatch $script:NamePattern) { $errors.Add("$c '$($v[$c])' isn't a valid name") }
        }
        if ($v.PreferredName -and $v.PreferredName -notmatch $script:NamePattern) { $errors.Add("PreferredName '$($v.PreferredName)' isn't a valid name") }
        if ($v.JobTitle -notmatch $script:TitlePattern) { $errors.Add("job title '$($v.JobTitle)' isn't valid") }
        if (-not $Policy.departments.Contains($v.Department)) { $errors.Add("department '$($v.Department)' isn't in the policy") }
        if (-not $Policy.locations.Contains($v.Location)) { $errors.Add("location '$($v.Location)' isn't in the policy") }
        if (-not $Policy.employmentTypes.Contains($v.EmploymentType)) { $errors.Add("employment type '$($v.EmploymentType)' isn't in the policy") }
        if ($v.ManagerId -and $v.ManagerId -notmatch '^E\d{4,6}$') { $errors.Add("manager ID '$($v.ManagerId)' should look like E1234") }
        if ($v.ManagerId -and $v.ManagerId -eq $v.EmployeeId) { $errors.Add('someone can''t be their own manager') }

        $start = ConvertTo-TurnstileDate $v.StartDate
        $end = ConvertTo-TurnstileDate $v.EndDate
        if (-not $start) { $errors.Add("start date '$($v.StartDate)' should be a date like 2026-10-19") }
        if ($v.EndDate -and -not $end) { $errors.Add("end date '$($v.EndDate)' should be a date like 2026-10-19") }
        if ($start -and $end -and $end -lt $start) { $errors.Add('the end date is before the start date') }
        if ($v.EmploymentType -eq 'Contractor' -and -not $v.EndDate) { $errors.Add('contractors need an end date') }

        if ($errors.Count) {
            & $issue 'Error' $line $v.EmployeeId "Row rejected: $($errors -join '; ')."
            if ($v.EmployeeId -match '^E\d{4,6}$') { [void] $rejected.Add($v.EmployeeId) }
            continue
        }
        $records.Add([pscustomobject]@{
            EmployeeId     = $v.EmployeeId
            FirstName      = $v.FirstName
            LastName       = $v.LastName
            PreferredName  = $v.PreferredName
            Department     = $v.Department
            JobTitle       = $v.JobTitle
            Location       = $v.Location
            ManagerId      = $v.ManagerId
            EmploymentType = $v.EmploymentType
            StartDate      = $start
            EndDate        = $end
            Line           = $line
        })
    }

    # The same person twice: there's no way to know which row is right, so neither is used.
    $dupes = $records | Group-Object EmployeeId | Where-Object Count -gt 1
    foreach ($d in $dupes) {
        foreach ($r in $d.Group) {
            & $issue 'Error' $r.Line $r.EmployeeId "Row rejected: $($r.EmployeeId) appears $($d.Count) times in the export."
            [void] $records.Remove($r)
        }
        [void] $rejected.Add($d.Name)
    }

    $ids = [Collections.Generic.HashSet[string]]::new()
    foreach ($r in $records) { [void] $ids.Add($r.EmployeeId) }
    foreach ($r in $records) {
        if ($r.ManagerId -and -not $ids.Contains($r.ManagerId) -and -not $rejected.Contains($r.ManagerId)) {
            & $issue 'Warning' $r.Line $r.EmployeeId "Manager $($r.ManagerId) isn't in the export, so the manager wasn't set."
        }
    }

    [pscustomobject]@{
        Path        = $Path
        RowCount    = $rows.Count
        Records     = @($records)
        Issues      = @($issues | Sort-Object Line)
        RejectedIds = @($rejected)
    }
}
