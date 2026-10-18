#Requires -Version 7.4
<#
    A week at Windward Freight & Shipping (an invented company in Kingstown, St Vincent).

    Builds a practice directory in .\demo-output, then runs Turnstile against each day's HR
    export in data\hr. Nothing outside .\demo-output is touched.

        pwsh .\demo.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'A demo for people at a console.')]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Turnstile/Turnstile.psd1') -Force

$out = Join-Path $PSScriptRoot 'demo-output'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null
$directoryPath = Join-Path $out 'directory.json'
$auditPath = Join-Path $out 'audit.log'
$hr = { param($day) Join-Path $PSScriptRoot "data/hr/$day.csv" }

function Show-Day([string] $Title) {
    Write-Host ''
    Write-Host ("── $Title " + ('─' * [Math]::Max(0, 76 - $Title.Length))) -ForegroundColor White
}

function Edit-Directory([scriptblock] $Change) {
    $state = Get-Content $directoryPath -Raw | ConvertFrom-Json -AsHashtable
    & $Change $state
    $state | ConvertTo-Json -Depth 8 | Set-Content $directoryPath -Encoding utf8NoBOM
}

# ---- The directory as it stood before Turnstile ----------------------------------------
$groups = @(
    'All Staff', 'Kingstown Office', 'Bequia Office', 'Contractors', 'Management', 'People Managers',
    'Finance', 'Finance Share', 'Finance Approvers', 'Payroll', 'Port Ops', 'Port Ops Rota',
    'Customer Service', 'Bookings System', 'IT Team', 'Helpdesk', 'Server Admins', 'HR', 'HR Confidential', 'Domain Admins',
    'Ferry Terminal Project'
) | ForEach-Object { [ordered]@{ name = $_ } }
$serviceAccount = { param($name, $description, $groupList)
    [ordered]@{ username = $name; employeeId = $null; displayName = $name; description = $description; enabled = $true
        ou = 'OU=Service Accounts,DC=windwardfreight,DC=example'; groups = @($groupList) } }
$state = [ordered]@{
    domain = 'windwardfreight.example'
    groups = $groups
    users  = @(
        (& $serviceAccount 'Administrator' 'Built-in administrator' @('Domain Admins')),
        (& $serviceAccount 'svc-backup' 'Nightly backup job' @()),
        (& $serviceAccount 'svc-scanner' 'Office scanner, scan-to-email' @())
    )
}
$state | ConvertTo-Json -Depth 8 | Set-Content $directoryPath -Encoding utf8NoBOM

Write-Host 'TURNSTILE: joiners, movers and leavers for Windward Freight & Shipping Ltd (invented), Kingstown'
Write-Host 'Practice directory: demo-output\directory.json   Audit log: demo-output\audit.log'

Show-Day 'Friday 16 October: Turnstile takes over the 19 existing staff'
$run = Invoke-TurnstileSync -HrPath (& $hr '2026-10-16') -DirectoryPath $directoryPath -Today '2026-10-16'
Write-Host "  $($run.Applied) changes applied quietly (accounts, groups). Three service accounts with no employee ID are never touched."
# Admin rights granted before Turnstile (with no approval on record), and one permission someone added by hand.
Edit-Directory {
    param($s)
    ($s.users | Where-Object username -eq 'lystra.baptiste').groups += 'Finance Approvers'
    ($s.users | Where-Object username -eq 'ronald.cottle').groups += 'Payroll'
    ($s.users | Where-Object username -eq 'jerome.delves').groups += 'Ferry Terminal Project'
}
Write-Host '  From before Turnstile, with no approval on record: Lystra (Finance Approvers) and Ronald (Payroll).'
Write-Host '  Added by hand some time ago: Jerome, to Ferry Terminal Project (a group the policy knows nothing about).'

Show-Day 'Monday 19 October: the plan first (Get-TurnstilePlan changes nothing; nor does -WhatIf)'
$before = (Get-FileHash $directoryPath).Hash
Get-TurnstilePlan -HrPath (& $hr '2026-10-19') -DirectoryPath $directoryPath -Today '2026-10-19' | Show-TurnstilePlan
Write-Host ("  Directory file unchanged by looking: {0}" -f ($before -eq (Get-FileHash $directoryPath).Hash))

Show-Day 'Monday 19 October: for real'
$monday = Invoke-TurnstileSync -HrPath (& $hr '2026-10-19') -DirectoryPath $directoryPath -Today '2026-10-19'
Write-Host ("  Done: {0} changes applied. Waiting for a decision:" -f $monday.Applied)
Get-TurnstileApproval -DirectoryPath $directoryPath -Status Pending | ForEach-Object {
    $what = if ($_.Kind -eq 'Confirm') { 'confirm access they already have' } else { 'new' }
    Write-Host ("    {0}  {1,-17} {2,-18} {3}: {4}" -f $_.Id, $_.Username, $_.Group, $_.Title, $what) -ForegroundColor Magenta
}

Show-Day 'Monday 19 October, later: the decisions'
$decide = { param($what, [scriptblock] $do)
    try { $r = & $do; Write-Host "  $what" ; Write-Host ("    -> {0} {1} by {2}{3}" -f $r.Id, $r.Status.ToLower(), $r.DecidedBy, $(if ($r.ExpiresOn) { ", until $($r.ExpiresOn)" } else { '' })) -ForegroundColor Green }
    catch { Write-Host "  $what"; Write-Host "    -> refused: $($_.Exception.Message)" -ForegroundColor Red } }
$ids = @{}; Get-TurnstileApproval -DirectoryPath $directoryPath -Status Pending | ForEach-Object { $ids[$_.Username] = $_.Id }
& $decide 'Andre tries to approve his own Server Admins request' {
    Approve-TurnstileAccess -DirectoryPath $directoryPath -Id $ids['andre.cupid'] -ApprovedBy andre.cupid -Ticket CHG-1042 -Today '2026-10-19' }
& $decide 'Akeem from the help desk tries to approve it for him' {
    Approve-TurnstileAccess -DirectoryPath $directoryPath -Id $ids['andre.cupid'] -ApprovedBy akeem.ballantyne -Ticket CHG-1042 -Today '2026-10-19' }
& $decide 'Dwight, Andre''s manager, approves it, with a change ticket' {
    Approve-TurnstileAccess -DirectoryPath $directoryPath -Id $ids['andre.cupid'] -ApprovedBy dwight.robertson -Ticket CHG-1042 -Today '2026-10-19' }
& $decide 'Garfield confirms Lystra''s Finance Approvers access' {
    Approve-TurnstileAccess -DirectoryPath $directoryPath -Id $ids['lystra.baptiste'] -ApprovedBy garfield.providence -Ticket CHG-1043 -Today '2026-10-19' }
& $decide 'Lystra, who owns the Payroll group, confirms Ronald''s access for 60 days' {
    Approve-TurnstileAccess -DirectoryPath $directoryPath -Id $ids['ronald.cottle'] -ApprovedBy lystra.baptiste -Ticket CHG-1044 -Days 60 -Today '2026-10-19' }
Write-Host '  Each decision is written to the audit log first. That entry is what makes it count.' -ForegroundColor DarkGray

Show-Day 'Tuesday 20 October: a leaver, a contractor, and the fixed row'
Invoke-TurnstileSync -HrPath (& $hr '2026-10-20') -DirectoryPath $directoryPath -Today '2026-10-20' | Show-TurnstilePlan

Show-Day 'Wednesday 21 October: the HR export arrives cut short'
Invoke-TurnstileSync -HrPath (& $hr '2026-10-21') -DirectoryPath $directoryPath -Today '2026-10-21' | ForEach-Object {
    $plan = $_.Plan
    Write-Host "  HR export: $($plan.HrRows) rows (normally 24)."
    Write-Host "  STOPPED: $($plan.BlockedReason)" -ForegroundColor Red
    Write-Host '  Nothing changed. A tool that treated "missing from the export" as "has left" would have locked out most of the company.' -ForegroundColor DarkGray
}

Show-Day 'Thursday 22 October: an HR system glitch gives Port Operations an end date'
Invoke-TurnstileSync -HrPath (& $hr '2026-10-22') -DirectoryPath $directoryPath -Today '2026-10-22' | ForEach-Object {
    Write-Host "  STOPPED: $($_.Plan.BlockedReason)" -ForegroundColor Red
    Write-Host '  Nothing changed. Port Operations kept working while HR fixed the export.' -ForegroundColor DarkGray
}

Show-Day 'Thursday night: someone edits approvals.json to stretch Andre''s approval to 2030'
$approvalsPath = Join-Path $out 'approvals.json'
$saved = Get-Content $approvalsPath -Raw
$edited = $saved | ConvertFrom-Json -AsHashtable
($edited.requests | Where-Object username -eq 'andre.cupid').expiresOn = '2030-01-01'
$edited | ConvertTo-Json -Depth 6 | Set-Content $approvalsPath -Encoding utf8NoBOM
Get-TurnstilePlan -HrPath (& $hr '2026-10-23') -DirectoryPath $directoryPath -Today '2026-10-23' | ForEach-Object {
    $_.Issues | Where-Object Severity -eq 'Error' | ForEach-Object { Write-Host "  ! $($_.Message)" -ForegroundColor Red }
    ($_.Actions | Where-Object Username -eq 'andre.cupid').Detail | ForEach-Object { Write-Host "  andre.cupid: $_" -ForegroundColor Magenta }
}
Write-Host '  The audit log says 2027-01-17, so the edited approval doesn''t count. (Putting the file back.)' -ForegroundColor DarkGray
Set-Content $approvalsPath $saved -NoNewline -Encoding utf8NoBOM

Show-Day 'Friday 23 October: back to normal, and running twice changes nothing'
$friday = Invoke-TurnstileSync -HrPath (& $hr '2026-10-23') -DirectoryPath $directoryPath -Today '2026-10-23'
$again = Invoke-TurnstileSync -HrPath (& $hr '2026-10-23') -DirectoryPath $directoryPath -Today '2026-10-23'
Write-Host "  First run: $($friday.Applied) changes. Second run: $($again.Applied) changes."

Show-Day 'Friday 23 October: the access review'
$review = Get-TurnstileAccessReview -DirectoryPath $directoryPath -HrPath (& $hr '2026-10-23') -Today '2026-10-23'
$review | Show-TurnstileAccessReview
$files = $review | Export-TurnstileAccessReview -Folder (Join-Path $out 'review')
Write-Host "  For managers to sign off: demo-output\review\$(Split-Path -Leaf $files[1]) (one row per membership, with a Decision column)" -ForegroundColor DarkGray

Show-Day 'Monday 26 October: Zoë starts'
Invoke-TurnstileSync -HrPath (& $hr '2026-10-26') -DirectoryPath $directoryPath -Today '2026-10-26' | Show-TurnstilePlan
$note = Get-Content (Join-Path $out 'new-starter-notes/zoe.ollivierre.txt') -Raw
Write-Host '  Her manager''s note (password hidden here):' -ForegroundColor DarkGray
($note -replace '(Temporary password:\s+)\S+', '$1****************').TrimEnd().Split("`n") | Select-Object -First 8 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

Show-Day 'Friday 20 November: Desmond''s 30 days are up'
Invoke-TurnstileSync -HrPath (& $hr '2026-11-20') -DirectoryPath $directoryPath -Today '2026-11-20' | Show-TurnstilePlan

Show-Day 'Monday 18 January 2027: approvals run out, and so does a contract'
Invoke-TurnstileSync -HrPath (& $hr '2027-01-18') -DirectoryPath $directoryPath -Today '2027-01-18' | Show-TurnstilePlan

Show-Day 'The audit log'
$check = Test-TurnstileAuditLog -Path $auditPath
Write-Host "  $($check.Entries) entries, chain intact: $($check.Valid)"
$lines = Get-Content $auditPath
$lines | Select-String '"event":"(Disable|RunRefused|ApprovalGranted)"' | Select-Object -First 4 | ForEach-Object {
    $entry = ($_.Line.Substring(65) | ConvertFrom-Json)
    Write-Host ("    #{0} {1} {2}: {3}" -f $entry.seq, $entry.event, $entry.target, $entry.detail) -ForegroundColor DarkGray
}
$tampered = Join-Path $out 'audit-tampered.log'
$lines -replace '"target":"desmond.hazell","detail":"Left on', '"target":"kevin.browne","detail":"Left on' | Set-Content $tampered -Encoding utf8NoBOM
$bad = Test-TurnstileAuditLog -Path $tampered
Write-Host "  Someone edits a copy to blame a different account: chain intact: $($bad.Valid). $($bad.Problem)" -ForegroundColor Yellow

Write-Host ''
Write-Host 'Everything above is in demo-output\: the directory, approvals, the audit log, the new-starter notes and the review.'
