function Export-TurnstileReport {
    <#
    .SYNOPSIS
        Write one HTML page showing where things stand: the next run's plan, approvals waiting,
        the access review, who holds admin rights, and the audit trail.
    .DESCRIPTION
        The page is a single file with no scripts and nothing loaded from the internet, so it
        can be emailed or opened anywhere. Every value from the directory, the HR export or
        the audit log is HTML-encoded, and the page's Content-Security-Policy forbids scripts
        outright, so a job title like <script>...</script> shows up as text and never runs.
        Changes nothing.
    .EXAMPLE
        Export-TurnstileReport -DirectoryPath .\demo-output\directory.json -HrPath .\data\hr\2026-10-23.csv -Path .\report.html
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $DirectoryPath,
        [Parameter(Mandatory)][string] $Path,
        [string] $HrPath,
        [string] $PolicyPath = $script:DefaultPolicy,
        [string] $ApprovalPath,
        [string] $AuditPath,
        [datetime] $Today = (Get-Date).Date,
        [int] $AuditEntries = 40
    )
    $Today = $Today.Date
    $policy = Read-TurnstilePolicy -Path $PolicyPath
    $directory = Open-TurnstileDirectory -Path $DirectoryPath
    $paths = Get-TurnstilePaths -Directory $directory -ApprovalPath $ApprovalPath -AuditPath $AuditPath
    $common = @{ DirectoryPath = $DirectoryPath; PolicyPath = $PolicyPath; ApprovalPath = $paths.Approvals; AuditPath = $paths.Audit; Today = $Today }
    $plan = if ($HrPath) { Get-TurnstilePlan -HrPath $HrPath @common } else { $null }
    $reviewArgs = $common.Clone(); if ($HrPath) { $reviewArgs.HrPath = $HrPath }
    $review = Get-TurnstileAccessReview @reviewArgs
    $requests = @(Get-TurnstileApproval -DirectoryPath $DirectoryPath -ApprovalPath $paths.Approvals)
    $chain = Test-TurnstileAuditLog -Path $paths.Audit

    $e = { param($value) [Net.WebUtility]::HtmlEncode("$value") }
    $html = [Text.StringBuilder]::new()
    $w = { param([string] $text) [void] $html.Append($text) }

    # ---- Head --------------------------------------------------------------------------
    & $w @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
<meta name="referrer" content="no-referrer">
<title>Turnstile report: $(& $e $policy.organisation), $(Format-TurnstileDate $Today)</title>
<style>
$($script:ReportCss)
</style>
</head>
<body>
<header class="top">
  <div class="wrap">
    <p class="eyebrow">Turnstile · joiners, movers and leavers</p>
    <h1>$(& $e $policy.organisation)</h1>
    <p class="sub">Report for $(Format-TurnstileDate $Today -Long). Generated $(& $e ([DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm zzz', [Globalization.CultureInfo]::InvariantCulture))) from $(& $e (Split-Path -Leaf $directory.Path))$(if ($HrPath) { " and $(& $e (Split-Path -Leaf $HrPath))" }).</p>
  </div>
</header>
<main class="wrap">
"@

    # ---- Status tiles ------------------------------------------------------------------
    $pending = @($requests | Where-Object Status -eq 'Pending')
    $ready = if ($plan) { @($plan.Actions | Where-Object Status -eq 'Ready').Count } else { $null }
    $tile = { param($label, $value, $note, $tone) "<div class=""tile $tone""><span class=""label"">$(& $e $label)</span><span class=""value"">$(& $e $value)</span><span class=""note"">$(& $e $note)</span></div>" }
    & $w '<section class="tiles" aria-label="Summary">'
    $noLog = -not (Test-Path -LiteralPath $paths.Audit)
    if ($noLog) {
        & $w (& $tile 'Audit log' 'Empty' 'nothing recorded yet' 'plain')
    } elseif ($chain.Valid) {
        & $w (& $tile 'Audit log' 'Intact' "$($chain.Entries) entries, hash chain checked" 'good')
    } else {
        & $w (& $tile 'Audit log' 'FAILS CHECK' $chain.Problem 'bad')
    }
    if ($plan) {
        if ($plan.Blocked) { & $w (& $tile 'Next run' 'Stopped' 'A safety stop will refuse it' 'bad') }
        else { & $w (& $tile 'Next run' "$ready change$(if ($ready -ne 1) { 's' })" "$($plan.Summary.NeedsApproval) waiting for approval" $(if ($ready) { 'info' } else { 'good' })) }
    }
    & $w (& $tile 'Approvals waiting' $pending.Count $(if ($pending) { "oldest from $(($pending | Sort-Object RequestedOn)[0].RequestedOn)" } else { 'nothing to decide' }) $(if ($pending) { 'warn' } else { 'good' }))
    & $w (& $tile 'Review findings' "$($review.Summary.High) high" "$($review.Summary.Medium) medium, $($review.Summary.Low) low" $(if ($review.Summary.High) { 'bad' } elseif ($review.Summary.Medium) { 'warn' } else { 'good' }))
    $privCount = $review.Summary.Privileged
    & $w (& $tile 'People' $review.Summary.People "$($review.Summary.Accounts) accounts, $privCount privileged membership$(if ($privCount -ne 1) { 's' })" 'plain')
    & $w '</section>'

    & $w '<nav class="toc" aria-label="Sections"><a href="#plan">Next run</a><a href="#approvals">Approvals</a><a href="#review">Access review</a><a href="#privileged">Admin rights</a><a href="#activity">Activity</a></nav>'

    # ---- The plan ------------------------------------------------------------------------
    & $w '<section id="plan"><h2>What the next run will do</h2>'
    if (-not $plan) {
        & $w '<p class="muted">No HR export was given, so there''s no plan. Run with -HrPath to include one.</p>'
    } else {
        & $w "<p class=""muted"">From $(& $e (Split-Path -Leaf $plan.HrPath)) ($($plan.HrRows) rows), as of $(Format-TurnstileDate $plan.Today -Long). Nothing has been changed yet.</p>"
        if ($plan.Blocked) { & $w "<div class=""banner bad""><strong>Stopped.</strong> $(& $e $plan.BlockedReason) Nothing will be changed.</div>" }
        $kinds = @{ Create = @('New account', 'add'); Enable = @('Switch on', 'add'); Update = @('Update', 'change'); Move = @('Move', 'change')
            AddGroup = @('Add to group', 'add'); RemoveGroup = @('Remove from group', 'remove'); Disable = @('Switch off', 'stop'); Delete = @('Delete', 'stop'); Confirm = @('Confirm', 'ask') }
        if (-not $plan.Actions) { & $w '<p class="empty">Nothing to do: the directory already matches HR.</p>' }
        else {
            & $w '<table><thead><tr><th>Who</th><th>Change</th><th>Details</th></tr></thead><tbody>'
            foreach ($group in $plan.Actions | Group-Object Username) {
                $first = $true
                foreach ($a in $group.Group) {
                    $k = $kinds[$a.Kind]
                    $badge = if ($a.Status -eq 'NeedsApproval') { '<span class="badge ask">Needs approval</span>' } else { "<span class=""badge $($k[1])"">$($k[0])</span>" }
                    $who = if ($first) { "<strong>$(& $e $a.Username)</strong><br><span class=""muted"">$(& $e $a.Name) · $(& $e $a.EmployeeId)</span>" } else { '' }
                    & $w "<tr$(if ($first) { ' class="first"' })><td>$who</td><td>$badge</td><td>$(& $e $a.Detail)</td></tr>"
                    $first = $false
                }
            }
            & $w '</tbody></table>'
        }
        if ($plan.Issues) {
            & $w '<details open><summary>Problems found in the export or directory</summary><ul class="issues">'
            foreach ($i in $plan.Issues) {
                $where = if ($i.Line) { "line $($i.Line)" } else { $i.EmployeeId }
                & $w "<li class=""$($i.Severity.ToLower())""><span class=""sev"">$(& $e $i.Severity)</span> <span class=""muted"">$(& $e $where)</span> $(& $e $i.Message)</li>"
            }
            & $w '</ul></details>'
        }
    }
    & $w '</section>'

    # ---- Approvals -----------------------------------------------------------------------
    & $w '<section id="approvals"><h2>Approvals</h2>'
    if ($pending) {
        & $w '<h3>Waiting for a decision</h3><table><thead><tr><th>Request</th><th>Who</th><th>Group</th><th>Why</th><th>Asked</th></tr></thead><tbody>'
        foreach ($r in $pending) {
            $why = if ($r.Kind -eq 'Confirm') { "Confirm access they already have ($($r.Title))" } else { "Their job: $($r.Title)" }
            $age = ($Today - (ConvertTo-TurnstileDate $r.RequestedOn)).Days
            & $w "<tr><td><code>$(& $e $r.Id)</code></td><td>$(& $e $r.Username)</td><td><strong>$(& $e $r.Group)</strong></td><td>$(& $e $why)</td><td>$(& $e $r.RequestedOn)<br><span class=""muted"">$(if ($age -eq 0) { 'today' } elseif ($age -eq 1) { 'yesterday' } else { "$age days ago" })</span></td></tr>"
        }
        & $w '</tbody></table>'
        & $w '<p class="muted">Decide with <code>Approve-TurnstileAccess</code> or <code>Deny-TurnstileAccess</code>. Only the person''s manager or the group''s owner can, with a change ticket.</p>'
    } else { & $w '<p class="empty">Nothing waiting for a decision.</p>' }
    $decided = @($requests | Where-Object Status -ne 'Pending' | Select-Object -Last 12)
    if ($decided) {
        & $w '<details><summary>Recent decisions and endings</summary><table><thead><tr><th>Request</th><th>Who</th><th>Group</th><th>Outcome</th><th>By</th><th>Ticket</th><th>Until</th></tr></thead><tbody>'
        foreach ($r in [Linq.Enumerable]::Reverse([object[]] $decided)) {
            $tone = switch ($r.Status) { 'Approved' { 'add' } 'Rejected' { 'stop' } 'Revoked' { 'stop' } default { 'change' } }
            & $w "<tr><td><code>$(& $e $r.Id)</code></td><td>$(& $e $r.Username)</td><td>$(& $e $r.Group)</td><td><span class=""badge $tone"">$(& $e $r.Status)</span></td><td>$(& $e $r.DecidedBy)</td><td>$(& $e $r.Ticket)</td><td>$(& $e $r.ExpiresOn)</td></tr>"
        }
        & $w '</tbody></table></details>'
    }
    & $w '</section>'

    # ---- Access review ---------------------------------------------------------------------
    & $w '<section id="review"><h2>Access review</h2>'
    if ($review.Findings) {
        & $w '<ul class="findings">'
        foreach ($f in $review.Findings) {
            & $w "<li class=""$($f.Severity.ToLower())""><span class=""sev"">$(& $e $f.Severity)</span><div><strong>$(& $e $f.Category)</strong><br>$(& $e $f.Detail)</div></li>"
        }
        & $w '</ul>'
    } else { & $w '<p class="empty">Nothing to flag.</p>' }
    & $w '<p class="muted">For managers to sign off, export the full list with <code>Export-TurnstileAccessReview</code>.</p></section>'

    # ---- Privileged access ------------------------------------------------------------------
    & $w '<section id="privileged"><h2>Who holds admin rights</h2>'
    $priv = @($review.Entries | Where-Object Privileged)
    if ($priv) {
        & $w '<table><thead><tr><th>Group</th><th>Who</th><th>Basis</th><th>Until</th></tr></thead><tbody>'
        foreach ($p in $priv | Sort-Object Group, Username) {
            $tone = if ($p.Source -like 'Approved*') { 'add' } elseif ($p.Source -eq 'Service account') { 'change' } else { 'stop' }
            & $w "<tr><td><strong>$(& $e $p.Group)</strong></td><td>$(& $e $p.Username)<br><span class=""muted"">$(& $e $p.Name)</span></td><td><span class=""badge $tone"">$(& $e $p.Source)</span></td><td>$(& $e $p.ApprovalExpires)</td></tr>"
        }
        & $w '</tbody></table>'
    } else { & $w '<p class="empty">Nobody holds a privileged group.</p>' }
    & $w '</section>'

    # ---- Activity -------------------------------------------------------------------------
    & $w '<section id="activity"><h2>Activity</h2>'
    if (-not $chain.Valid -and (Test-Path -LiteralPath $paths.Audit)) {
        & $w "<div class=""banner bad""><strong>The audit log fails its check.</strong> $(& $e $chain.Problem) The entries below can't be trusted until this is explained.</div>"
    } elseif ($chain.Valid) {
        & $w "<div class=""banner good"">All $($chain.Entries) entries checked: each one's SHA-256 hash matches, and each points at the one before. Nothing has been edited, removed or reordered.</div>"
    }
    if (Test-Path -LiteralPath $paths.Audit) {
        $lines = @(Get-Content -LiteralPath $paths.Audit -Tail $AuditEntries)
        $parsed = foreach ($line in $lines) { try { $line.Substring(65) | ConvertFrom-Json } catch { } }
        $runDays = @{}
        foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $paths.Audit).Path)) {
            if ($line -like '*"event":"RunStarted"*') { $x = $line.Substring(65) | ConvertFrom-Json; if ($x.data.PSObject.Properties['day']) { $runDays[$x.run] = $x.data.day } }
        }
        $tones = @{ Disable = 'stop'; Delete = 'stop'; RunRefused = 'stop'; Failed = 'stop'; SafetyOverride = 'stop'; ApprovalDenied = 'stop'; ApprovalRevoked = 'stop'
            Create = 'add'; Enable = 'add'; AddGroup = 'add'; ApprovalGranted = 'add'; RemoveGroup = 'remove'; ApprovalRequested = 'ask' }
        & $w "<p class=""muted"">The latest $(@($parsed).Count) entries, newest first.</p><table class=""log""><thead><tr><th>#</th><th>Day</th><th>Event</th><th>Account</th><th>Details</th></tr></thead><tbody>"
        foreach ($x in [Linq.Enumerable]::Reverse([object[]] @($parsed))) {
            $day = if ($runDays.ContainsKey($x.run)) { $runDays[$x.run] } elseif ($x.data -and $x.data.PSObject.Properties['day']) { $x.data.day } else { '' }
            $tone = if ($tones.ContainsKey($x.event)) { $tones[$x.event] } else { 'plain' }
            & $w "<tr><td class=""num"">$(& $e $x.seq)</td><td class=""nowrap"">$(& $e $day)</td><td><span class=""badge $tone"">$(& $e $x.event)</span></td><td class=""nowrap"">$(& $e $x.target)</td><td>$(& $e $x.detail)</td></tr>"
        }
        & $w '</tbody></table>'
    } else { & $w '<p class="empty">No audit log yet.</p>' }
    & $w '</section>'

    & $w @"
</main>
<footer class="wrap muted">Made by Turnstile. $(& $e $policy.organisation) and its people are invented for the demo; Kingstown and Bequia are real. This page runs no scripts.</footer>
</body>
</html>
"@
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
    Set-Content -LiteralPath $Path -Value $html.ToString() -Encoding utf8NoBOM
    Get-Item -LiteralPath $Path
}

$script:ReportCss = @'
:root {
  --bg: #f6f7f4; --card: #ffffff; --ink: #1d2a2e; --muted: #5d6b6f; --line: #dfe4e1;
  --head: #0d3b45; --head-ink: #f1f7f5; --accent: #0f7c6d;
  --good: #1f7a4d; --good-bg: #e5f4ec; --warn: #8a5a00; --warn-bg: #fdf1d8;
  --bad: #a3271f; --bad-bg: #fbe6e3; --info: #1e5c8a; --info-bg: #e3eff8;
  --ask: #6b3fa0; --ask-bg: #efe7f8;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #111a1c; --card: #172326; --ink: #e3ebe8; --muted: #9aaaa6; --line: #2a3a3d;
    --head: #0a2a31; --head-ink: #e8f3f0; --accent: #4fc1ae;
    --good: #6fd19c; --good-bg: #173326; --warn: #f1c26b; --warn-bg: #3a2e14;
    --bad: #ff9a8f; --bad-bg: #3d1d1a; --info: #8cc4f0; --info-bg: #15293a;
    --ask: #c9a5f2; --ask-bg: #2a1f3a;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 15px/1.5 "Segoe UI", system-ui, -apple-system, Roboto, sans-serif; }
.wrap { max-width: 1100px; margin: 0 auto; padding: 0 20px; }
.top { background: var(--head); color: var(--head-ink); padding: 28px 0 24px; border-bottom: 4px solid var(--accent); }
.top h1 { margin: 2px 0 6px; font-size: 28px; letter-spacing: -0.01em; }
.eyebrow { margin: 0; text-transform: uppercase; letter-spacing: 0.12em; font-size: 12px; opacity: 0.8; }
.sub { margin: 0; opacity: 0.85; }
h2 { font-size: 20px; margin: 0 0 6px; }
h3 { font-size: 15px; margin: 16px 0 8px; }
section { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 20px 22px; margin: 18px 0; }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; background: none; border: 0; padding: 0; margin-top: 22px; }
.tile { background: var(--card); border: 1px solid var(--line); border-left: 5px solid var(--muted); border-radius: 10px; padding: 12px 14px; display: flex; flex-direction: column; min-width: 0; }
.tile .label { font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); }
.tile .value { font-size: 24px; font-weight: 650; margin: 2px 0; }
.tile .note { font-size: 13px; color: var(--muted); overflow-wrap: anywhere; }
.tile.good { border-left-color: var(--good); } .tile.good .value { color: var(--good); }
.tile.warn { border-left-color: var(--warn); } .tile.warn .value { color: var(--warn); }
.tile.bad { border-left-color: var(--bad); } .tile.bad .value { color: var(--bad); }
.tile.info { border-left-color: var(--info); } .tile.info .value { color: var(--info); }
.toc { display: flex; flex-wrap: wrap; gap: 6px 18px; margin: 16px 2px 0; font-size: 14px; }
.toc a { color: var(--accent); text-decoration: none; font-weight: 600; }
.toc a:hover, .toc a:focus { text-decoration: underline; }
table { width: 100%; border-collapse: collapse; margin: 10px 0; font-size: 14px; }
th { text-align: left; font-size: 12px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); border-bottom: 2px solid var(--line); padding: 6px 8px; }
td { border-bottom: 1px solid var(--line); padding: 7px 8px; vertical-align: top; overflow-wrap: anywhere; }
tr.first td { border-top: 2px solid var(--line); }
td.num { color: var(--muted); font-variant-numeric: tabular-nums; white-space: nowrap; }
td.nowrap { white-space: nowrap; overflow-wrap: normal; }
.log td { font-size: 13px; }
.badge { display: inline-block; padding: 1px 8px; border-radius: 999px; font-size: 12px; font-weight: 600; white-space: nowrap; background: var(--line); color: var(--ink); }
.badge.add { background: var(--good-bg); color: var(--good); }
.badge.remove { background: var(--warn-bg); color: var(--warn); }
.badge.stop { background: var(--bad-bg); color: var(--bad); }
.badge.change { background: var(--info-bg); color: var(--info); }
.badge.ask { background: var(--ask-bg); color: var(--ask); }
.banner { border-radius: 8px; padding: 10px 14px; margin: 10px 0; }
.banner.bad { background: var(--bad-bg); color: var(--bad); }
.banner.good { background: var(--good-bg); color: var(--good); }
.muted { color: var(--muted); }
.empty { color: var(--muted); font-style: italic; }
code { font-family: Consolas, "Cascadia Mono", ui-monospace, monospace; font-size: 13px; background: var(--bg); padding: 1px 5px; border-radius: 4px; }
details { margin-top: 12px; }
summary { cursor: pointer; font-weight: 600; color: var(--accent); }
ul.issues, ul.findings { list-style: none; padding: 0; margin: 10px 0; }
ul.issues li { padding: 6px 0; border-bottom: 1px solid var(--line); }
ul.findings li { display: flex; gap: 12px; padding: 10px 0; border-bottom: 1px solid var(--line); }
.sev { display: inline-block; min-width: 70px; font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; }
.high .sev, .error .sev { color: var(--bad); }
.medium .sev, .warning .sev { color: var(--warn); }
.low .sev, .info .sev { color: var(--muted); }
footer { padding: 10px 20px 40px; font-size: 13px; }
@media (max-width: 640px) {
  .top h1 { font-size: 22px; }
  section { padding: 14px; }
  table, thead, tbody, tr, th, td { font-size: 13px; }
  th:nth-child(n+4), td:nth-child(n+4) { display: none; }
  .log th:nth-child(2), .log td:nth-child(2) { display: none; }
  .log th:nth-child(5), .log td:nth-child(5) { display: table-cell; }
  ul.findings li { flex-direction: column; gap: 2px; }
}
@media print {
  body { background: #fff; color: #000; }
  .top { background: none; color: #000; border-bottom: 2px solid #000; }
  section, .tile { break-inside: avoid; border-color: #999; }
  .toc { display: none; }
  details > *:not(summary) { display: block; }
}
'@
