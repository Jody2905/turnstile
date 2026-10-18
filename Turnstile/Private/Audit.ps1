# The audit log: one line per event, each line chained to the one before by a SHA-256 hash.
#
#   <hash> {"seq":12,"at":"...","run":"...","event":"Disable","target":"desmond.hazell",...,"prev":"<hash of line 11>"}
#
# The hash covers the JSON text exactly as written, and that JSON includes the previous
# line's hash. Change, delete or reorder any line and every hash after it stops matching,
# which Test-TurnstileAuditLog reports. (It can't stop someone rewriting the whole file, so
# a real deployment would also ship each line to a separate log server.)

$script:Genesis = '0' * 64

function Get-TurnstileAuditTail {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Seq = 0; Hash = $script:Genesis } }
    $last = Get-Content -LiteralPath $Path -Tail 1
    if (-not $last) { return @{ Seq = 0; Hash = $script:Genesis } }
    $space = $last.IndexOf(' ')
    $entry = $last.Substring($space + 1) | ConvertFrom-Json
    @{ Seq = [int] $entry.seq; Hash = $last.Substring(0, $space) }
}

function Add-TurnstileAuditEntry {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $EventName,
        [string] $Target = '',
        [string] $Detail = '',
        [hashtable] $Data = @{}
    )
    $tail = Get-TurnstileAuditTail -Path $Path
    $entry = [ordered]@{
        seq    = $tail.Seq + 1
        at     = [DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', [Globalization.CultureInfo]::InvariantCulture)
        run    = $RunId
        event  = $EventName
        target = $Target
        detail = $Detail
        data   = $Data
        prev   = $tail.Hash
    }
    $json = $entry | ConvertTo-Json -Compress -Depth 6
    $hash = Get-TurnstileHash $json
    Add-Content -LiteralPath $Path -Value "$hash $json" -Encoding utf8NoBOM
}

function Test-TurnstileAuditLog {
    <#
    .SYNOPSIS
        Check that nobody has edited, removed or reordered lines in an audit log.
    .OUTPUTS
        Valid (true/false), how many entries were checked, and where the first problem is.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    $result = { param($valid, $count, $problem) [pscustomobject]@{ Valid = $valid; Entries = $count; Problem = $problem } }
    if (-not (Test-Path -LiteralPath $Path)) { return & $result $false 0 "There's no audit log at $Path." }
    $previous = $script:Genesis
    $n = 0
    # ReadAllLines, not ReadLines: ReadLines keeps the file open if we stop early, and on
    # Windows an open file can't be written to or deleted.
    foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Path).Path)) {
        $n++
        $space = $line.IndexOf(' ')
        if ($space -ne 64) { return & $result $false ($n - 1) "Line ${n}: not a valid audit line." }
        $hash = $line.Substring(0, 64)
        $json = $line.Substring(65)
        if ((Get-TurnstileHash $json) -ne $hash) { return & $result $false ($n - 1) "Line ${n}: the entry was changed after it was written." }
        try { $entry = $json | ConvertFrom-Json } catch { return & $result $false ($n - 1) "Line ${n}: not valid JSON." }
        if ($entry.prev -ne $previous) { return & $result $false ($n - 1) "Line ${n}: the line before it is missing or out of order." }
        if ([int] $entry.seq -ne $n) { return & $result $false ($n - 1) "Line ${n}: expected entry $n but found $($entry.seq)." }
        $previous = $hash
    }
    & $result $true $n $null
}
