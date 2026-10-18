# Small helpers used everywhere: names, dates, hashes and passwords.

function ConvertTo-TurnstileAscii {
    # "Zoë" -> "Zoe": split accented letters into letter + accent, then drop the accents.
    param([AllowEmptyString()][string] $Text)
    $decomposed = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = [Text.StringBuilder]::new()
    foreach ($char in $decomposed.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($char) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void] $builder.Append($char)
        }
    }
    $builder.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function New-TurnstileUsername {
    <#
        first.last, lower case, letters only, at most MaxLength characters (Active Directory's
        sAMAccountName allows 20). If it's taken, add 2, 3, ... and shorten to fit.
          Zoë Ollivierre   -> zoe.ollivierre
          Shanice O'Garro  -> shanice.ogarro
          a second Kevin Browne -> kevin.browne2
    #>
    param(
        [Parameter(Mandatory)][string] $First,
        [Parameter(Mandatory)][string] $Last,
        [AllowEmptyCollection()][string[]] $Taken = @(),
        [int] $MaxLength = 20
    )
    $clean = { param($s) (ConvertTo-TurnstileAscii $s).ToLowerInvariant() -replace '[^a-z]', '' }
    $f = & $clean $First
    $l = & $clean $Last
    if (-not $f -or -not $l) { throw "Can't make a username from '$First $Last'." }

    # (Not called $taken: PowerShell variable names ignore case, so it would overwrite $Taken.)
    $used = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $Taken) { if ($t) { [void] $used.Add($t) } }

    $base = "$f.$l"
    if ($base.Length -gt $MaxLength) { $base = $base.Substring(0, $MaxLength).TrimEnd('.') }
    if (-not $used.Contains($base)) { return $base }
    for ($n = 2; $n -lt 1000; $n++) {
        $suffix = "$n"
        $stem = $base
        if ($stem.Length + $suffix.Length -gt $MaxLength) { $stem = $stem.Substring(0, $MaxLength - $suffix.Length).TrimEnd('.') }
        $candidate = "$stem$suffix"
        if (-not $used.Contains($candidate)) { return $candidate }
    }
    throw "No free username for '$First $Last'."
}

function New-TurnstilePassword {
    # A random temporary password: 16 characters from a cryptographic random generator,
    # with upper case, lower case, digits and symbols, and no look-alikes (0/O, 1/l/I).
    param([int] $Length = 16)
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#$%*+-=?@')
    $all = -join $sets
    $chars = [Collections.Generic.List[char]]::new()
    foreach ($set in $sets) { $chars.Add($set[[Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[[Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
    # Shuffle so the guaranteed characters aren't always first (Fisher-Yates).
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    -join $chars
}

function Get-TurnstileHash {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    -join ([Security.Cryptography.SHA256]::HashData($bytes) | ForEach-Object { $_.ToString('x2') })
}

function ConvertTo-TurnstileDate {
    # Only yyyy-MM-dd is accepted, so 03/04/2026 can never be read the wrong way round.
    param([AllowEmptyString()][AllowNull()][string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($Text.Trim(), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref] $parsed)) { return $parsed }
    return $null
}

function Format-TurnstileDate {
    param([AllowNull()] $Date, [switch] $Long)
    if ($null -eq $Date) { return '' }
    $d = [datetime] $Date
    if ($Long) { return $d.ToString('dddd d MMMM yyyy', [Globalization.CultureInfo]::InvariantCulture) }
    $d.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}

function Test-TurnstileBlank { param($Value) $null -eq $Value -or ($Value -is [string] -and $Value -eq '') }
