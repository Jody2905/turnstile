# Turnstile

Joiners, movers and leavers, handled automatically. Turnstile reads the HR department's daily
export and keeps everyone's user account in step with it: new starters get an account with the
right access, people who change jobs get their new access and lose the old, and leavers are
switched off the morning after their last day. It's careful about it. It shows its plan first,
won't act on a broken export, never hands out admin rights by itself, and records every change
in an audit log that shows if anyone edits it.

> Windward Freight & Shipping Ltd, its staff and its directory are invented, for the demo.
> Kingstown and Bequia are real.

**Status: Phase 1 of 4.** The engine and its tests, working on a practice directory. Coming
next: an approval step for privileged access and access reviews (Phase 2), an HTML report
(Phase 3), and an Active Directory connector plus CI (Phase 4).

## Run it

Needs PowerShell 7.4 or newer (`winget install Microsoft.PowerShell`, then open **PowerShell 7**).

```powershell
pwsh .\demo.ps1                 # a week at the company, explained step by step

Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck   # once
pwsh .\run-tests.ps1            # the tests
```

Using it directly:

```powershell
Import-Module .\Turnstile\Turnstile.psd1
Get-TurnstilePlan    -HrPath .\data\hr\2026-10-19.csv -DirectoryPath .\demo-output\directory.json | Show-TurnstilePlan
Invoke-TurnstileSync -HrPath .\data\hr\2026-10-19.csv -DirectoryPath .\demo-output\directory.json -WhatIf
Invoke-TurnstileSync -HrPath .\data\hr\2026-10-19.csv -DirectoryPath .\demo-output\directory.json | Show-TurnstilePlan
Test-TurnstileAuditLog -Path .\demo-output\audit.log
```

`-WhatIf` and `-Confirm` work as they do for any PowerShell command. `-Today 2026-10-19` runs
it as if it were that day.

## What happens to whom

| Who | When | What Turnstile does |
|---|---|---|
| **New starter** | up to 7 days before their first day | creates the account **switched off**, with their job's groups, and a note with a temporary password for their manager |
| | on their first day | switches it on |
| **Changes job or office** | the day HR records it | adds the new job's groups, **removes the old job's**, updates title, department and manager, moves the account to the right office's OU |
| **Changes name** | the day HR records it | updates the display name and surname; the username stays the same, so nothing breaks |
| **Contractor** | as for a new starter | also adds them to Contractors and sets the account to expire on their end date |
| **Leaver** | on their last day | nothing: they can work their last day (the account is already set to expire at the end of it) |
| | the morning after | **switches the account off first**, then removes every group, notes why, and moves it to the Disabled OU |
| | 30 days later | deletes it, even if HR has dropped them from the export by then |
| **Rehired** | their new first day | the same account comes back, with the new job's access |

Usernames are `first.last`: letters only, accents removed, at most 20 characters (the Active
Directory limit). Zoë Ollivierre is `zoe.ollivierre`, Shanice O'Garro is `shanice.ogarro`, and
a second Kevin Browne is `kevin.browne2`.

## Who gets what: the policy

[`config/policy.json`](config/policy.json) is the single place access is decided:

- **Everyone** gets All Staff, plus their office's group (Kingstown Office or Bequia Office).
- **Each department** has its groups: Finance gets Finance and Finance Share, and so on.
- **Job titles** add more: anyone whose title includes Manager, Director or Supervisor gets
  People Managers; IT Support titles get Helpdesk.
- **Privileged groups** (Domain Admins, Server Admins, Finance Approvers, Payroll) are **never
  added automatically**. Turnstile lists them as *needs approval* and leaves them out. Once
  someone has one, it's kept while their job still calls for it, and removed when it doesn't.

Access a person was given by hand is treated two ways:
- A **policy group** their job doesn't give them is removed, because the policy decides who's in it.
- **Any other group** is left alone and flagged every run for someone to review, because
  Turnstile can't know why it was granted.

Accounts with no employee ID (Administrator, service accounts) are never touched.

## Safety

HR exports go wrong: a truncated file, a bad batch update. Turnstile assumes they will.

- **Plan first.** `Get-TurnstilePlan` and `-WhatIf` show exactly what would change and touch
  nothing. A test proves the directory file is byte-for-byte the same afterwards.
- **A bad row is rejected on its own**, with the line number and the reason (an unknown
  department, a date like 19/10/2026 that could be read two ways, a contractor with no end
  date, the same person twice). That person's account is left as it was, and the rest of the
  export still counts.
- **Missing isn't the same as leaving.** Someone missing from the export is flagged, not
  switched off. Only an end date from HR makes someone a leaver.
- **Stops on a broken export.** If more than 20% of current staff are missing from the export,
  or more than 10% of accounts (at least 3) would be switched off at once, nothing is changed
  and the refusal is logged. An administrator can override with `-Force -Reason "..."`, and the
  reason goes in the audit log.
- **Leavers lose access first.** Switching the account off is the first action, before group
  removal and the OU move.
- **One failure stays contained.** If a change fails for one person, that person's remaining
  changes are skipped and everyone else is still done.
- **Passwords are written once.** Each temporary password is random (16 characters, from a
  cryptographic generator) and must be changed at first sign-in. It's written only to the
  manager's note, never to the directory file or the audit log. A test checks both.

## The audit log

One line per event: runs starting and finishing, every change (with old and new values), every
refusal and override. Each line carries a SHA-256 hash of its own contents *and* of the line
before it, so the lines form a chain:

```
7d1e…  {"seq":138,"at":"2026-10-20T07:00:02.114-04:00","event":"Disable","target":"desmond.hazell","detail":"Left on 2026-10-19: disable the account",...,"prev":"a93c…"}
```

`Test-TurnstileAuditLog` re-checks the chain and names the first line that doesn't fit: an
edited entry, a deleted or reordered line, or junk added to the file. One limit: removing lines
from the *end* leaves a shorter chain that's still valid. A real deployment would also send each
line to a separate log server as it's written.

## The demo week

`pwsh .\demo.ps1` builds a practice directory in `demo-output\` and plays through a week of
HR exports from `data\hr\`:

| Day | What happens |
|---|---|
| Fri 16 Oct | Turnstile takes over the 19 existing staff |
| Mon 19 Oct | the plan first; then Zoë (starts next Monday) is created switched off; a second Kevin Browne becomes `kevin.browne2`; Tricia moves from Port Operations to Finance; Keisha changes her name; Andre, a new systems administrator, is waiting for approval for Server Admins; a row with a department that doesn't exist is rejected |
| Tue 20 Oct | Desmond's last day was yesterday: switched off and stripped of access; a contractor starts; the rejected row, now fixed, goes through |
| Wed 21 Oct | the export arrives with 6 rows instead of 24: **stopped**, nothing changed |
| Thu 22 Oct | an HR glitch gives all of Port Operations an end date: **stopped** |
| Fri 23 Oct | a normal export; run it twice and the second run changes nothing |
| Mon 26 Oct | Zoë's first day: her account is switched on |
| Fri 20 Nov | Desmond's 30 days are up: his account is deleted |

Then it checks the audit log, edits a copy to blame the wrong person, and shows the check
catching it.

## Tests

60 Pester tests:

- **Every rule above**, one scenario at a time: joiners (including a manager and their new
  report joining the same day), movers, name changes, contractors, leavers, 30-day deletion,
  rehires, people who never started, hand-granted access, privileged groups, service accounts.
- **Every safety stop**, the override and its audit entry, `-WhatIf`, a second run finding
  nothing to do, and one failed change staying contained.
- **The audit log:** editing, deleting, reordering and adding lines are all caught.
- **Three random weeks.** A random company gets random changes every day for three weeks:
  people join, move, change name, leave and are rehired. After every run, every rule is
  checked across the whole directory (exactly the right groups, the right OU, switched on only
  between start and end date, no admin rights, unique usernames, an intact audit log), and a
  second run must find nothing to do.
- **The tests were checked too.** I broke six rules in the code on purpose (movers keeping
  old access, leavers keeping groups, admin rights granted automatically, leavers switched off a
  day late, no OU moves, username clashes ignored), and each break made tests fail.

## How it's organised

```
Turnstile/
  Turnstile.psd1        module manifest
  Public/               the commands you run
    Sync.ps1            Get-TurnstilePlan, Invoke-TurnstileSync, the new-starter note
    HrFeed.ps1          Import-TurnstileHrFeed: reading and checking the export
    Show.ps1            Show-TurnstilePlan
  Private/
    Planner.ps1         works out what should change (changes nothing itself)
    Policy.ps1          who gets which groups
    Directory.ps1       the practice directory; every change goes through one function,
                        so an Active Directory connector can slot in behind it
    Audit.ps1           the hash-chained audit log and Test-TurnstileAuditLog
    Common.ps1          usernames, passwords, dates, hashing
config/policy.json      the access policy
data/hr/                the demo week's HR exports
tests/                  Pester tests
demo.ps1, run-tests.ps1
```

## Built with

PowerShell 7, Pester 5. No other dependencies.
