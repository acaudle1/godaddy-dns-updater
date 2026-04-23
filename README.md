# GoDaddy + Microsoft 365 DNS Auth Automation

Automate SPF, DKIM, DMARC, and DMARC reporting alias setup for GoDaddy-managed domains that send mail through Microsoft 365.

## Features

- Enumerates domains from GoDaddy (`ote` or `prod`)
- Reads current SPF, DKIM, DMARC, and MX state
- Derives DKIM targets from Exchange Online (`Get-DkimSigningConfig`)
- Builds plan-first JSON reports before write operations
- Applies DNS updates only after explicit `-ApproveDkimTargets`
- Manages `rua@domain` and `ruf@domain` aliases on a target mailbox
- Skips DNS and Exchange operations for domains with no MX record

## Requirements

- PowerShell 7+
- GoDaddy API credentials (OTE and/or Production)
- Exchange Online permissions for:
  - `Get-DkimSigningConfig`
  - `New-DkimSigningConfig`
  - `Set-DkimSigningConfig` (if using `-EnableDkim`)
  - `Get-Mailbox`
  - `Set-Mailbox`
- Exchange module:
  - `Install-Module ExchangeOnlineManagement -Scope CurrentUser`

## Quick Start

1. Copy `.env.example` to `.env`.
2. Fill in your credentials and mailbox values.
3. Validate environment:
   - `pwsh ./dns-auth.ps1 -Command env-check -Environment ote`
4. Run OTE plan:
   - `pwsh ./dns-auth.ps1 -Command plan -Environment ote`
5. Review plan output in `./output/`.

## Environment Variables

Required:

- `DMARC_MAILBOX` (for example `dmarc@example.com`)
- OTE:
  - `GODADDY_OTE_KEY`
  - `GODADDY_OTE_SECRET`
- Production:
  - `GODADDY_PROD_KEY`
  - `GODADDY_PROD_SECRET`

Optional:

- `EXCLUDED_DOMAINS` (comma-separated)
- `PARKED_DOMAINS` (comma-separated)
- `SKIP_PARKED_DOMAINS` (`true`/`false`, default `true`)
- `GODADDY_REQUEST_DELAY_MS` (default `1100`)

Notes:

- `.env` values are loaded automatically.
- Existing process environment variables take precedence over `.env`.

## Commands

- Env template:
  - `pwsh ./dns-auth.ps1 -Command env-template -Environment ote`
- Env check:
  - `pwsh ./dns-auth.ps1 -Command env-check -Environment ote`
- API check:
  - `pwsh ./dns-auth.ps1 -Command api-check -Environment ote`
- Inventory:
  - `pwsh ./dns-auth.ps1 -Command inventory -Environment ote`
- Plan:
  - `pwsh ./dns-auth.ps1 -Command plan -Environment ote`
- Status:
  - `pwsh ./dns-auth.ps1 -Command status -Environment ote`
- Alias plan:
  - `pwsh ./dns-auth.ps1 -Command aliases-plan -Environment ote`
- Alias apply (dry-run):
  - `pwsh ./dns-auth.ps1 -Command aliases-apply -Environment ote`
- Alias apply (write):
  - `pwsh ./dns-auth.ps1 -Command aliases-apply -Environment ote -ApplyChanges`
- Apply DNS (dry-run):
  - `pwsh ./dns-auth.ps1 -Command apply -Environment ote -PlanFile .\output\plan-ote-YYYYMMDD-HHMMSS.json -ApproveDkimTargets`
- Apply DNS (write):
  - `pwsh ./dns-auth.ps1 -Command apply -Environment ote -PlanFile .\output\plan-ote-YYYYMMDD-HHMMSS.json -ApproveDkimTargets -ApplyChanges`
- Apply DNS + enable EXO DKIM:
  - `pwsh ./dns-auth.ps1 -Command apply -Environment ote -PlanFile .\output\plan-ote-YYYYMMDD-HHMMSS.json -ApproveDkimTargets -ApplyChanges -EnableDkim`
- Verify:
  - `pwsh ./dns-auth.ps1 -Command verify -Environment ote`
- Bootstrap dry-run:
  - `pwsh ./dns-auth.ps1 -Command bootstrap -Environment ote`
- Bootstrap write:
  - `pwsh ./dns-auth.ps1 -Command bootstrap -Environment ote -ApplyChanges -ApproveDkimTargets`

All command reports are written to `./output`.

## Recommended Rollout

1. Run complete flow in OTE:
   - `plan -> aliases-apply -> apply -> verify`
2. Confirm DKIM targets before any production write.
3. Repeat in production.
4. Keep DMARC at `p=none` initially.
5. Move to `quarantine`, then `reject` after monitoring.

## Publishing / Security Checklist

- Do not commit `.env`.
- Do not commit runtime reports from `output/*.json`.
- Rotate credentials immediately if they were ever exposed.
- Review and scrub organization-specific domain data before sharing logs.
