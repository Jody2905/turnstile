# PSScriptAnalyzer settings, used by CI's lint job:
#   Invoke-ScriptAnalyzer -Path .\Turnstile -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
# Every built-in rule runs. Where a rule is set aside in code, the reason is written next to it
# (a SuppressMessageAttribute with a Justification).
@{
    Severity = @('Error', 'Warning', 'Information')
    Rules    = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('7.4') }
    }
}
