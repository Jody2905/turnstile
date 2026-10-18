@{
    RootModule        = 'Turnstile.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '6f0c2a8e-3b7d-4c51-9a2e-7d5b1f4e8c30'
    Author            = 'Jody-Ann Trimmingham'
    Description       = 'Joiners, movers and leavers: keeps user accounts in line with the HR export, safely and with an audit trail.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Get-TurnstilePlan', 'Invoke-TurnstileSync', 'Show-TurnstilePlan', 'Import-TurnstileHrFeed', 'Test-TurnstileAuditLog',
        'Get-TurnstileApproval', 'Approve-TurnstileAccess', 'Deny-TurnstileAccess', 'Revoke-TurnstileAccess',
        'Get-TurnstileAccessReview', 'Show-TurnstileAccessReview', 'Export-TurnstileAccessReview'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('IAM', 'ActiveDirectory', 'Onboarding', 'JML') } }
}
