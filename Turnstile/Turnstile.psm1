# Turnstile: joiners, movers and leavers, from the HR export to the directory.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

foreach ($folder in 'Private', 'Public') {
    foreach ($file in Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter *.ps1 | Sort-Object Name) {
        . $file.FullName
    }
}
