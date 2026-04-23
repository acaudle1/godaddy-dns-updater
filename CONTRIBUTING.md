# Contributing

## Development Setup

1. Install PowerShell 7+.
2. Install Exchange module:
   - `Install-Module ExchangeOnlineManagement -Scope CurrentUser`
3. Copy `.env.example` to `.env` and set local values.
4. Run a safety check:
   - `pwsh ./dns-auth.ps1 -Command env-check -Environment ote`

## Contribution Guidelines

- Keep changes scoped and reviewable.
- Prefer additive changes over broad refactors.
- Preserve existing safety gates (`-ApproveDkimTargets`, dry-run defaults).
- Keep logs actionable and concise.

## Testing Expectations

Before opening a PR, run:

- `pwsh ./dns-auth.ps1 -Command env-check -Environment ote`
- `pwsh ./dns-auth.ps1 -Command api-check -Environment ote`
- `pwsh ./dns-auth.ps1 -Command plan -Environment ote`

If changing write paths, verify dry-run and write behavior in OTE first.
