param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("inventory", "plan", "status", "env-template", "env-check", "api-check", "bootstrap", "aliases-plan", "aliases-apply", "apply", "verify")]
    [string]$Command,

    [Alias("Environment")]
    [ValidateSet("ote", "prod")]
    [string]$TargetEnvironment = "ote",

    [string]$OutputDirectory = ".\output",
    [string]$EnvFile = ".\.env",
    [string]$PlanFile,
    [switch]$ApplyChanges,
    [switch]$ApproveDkimTargets,
    [switch]$EnableDkim
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$stamp] $Message"
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Resolve-AbsolutePath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Get-RequiredEnv {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Missing required environment variable: $Name"
    }
    $value
}

function Get-OptionalCsvEnv {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return @() }
    $value.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries).ForEach({ $_.Trim().ToLowerInvariant() })
}

function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("#")) { continue }

        $separatorIndex = $trimmed.IndexOf("=")
        if ($separatorIndex -lt 1) { continue }

        $name = $trimmed.Substring(0, $separatorIndex).Trim()
        $value = $trimmed.Substring($separatorIndex + 1).Trim()
        if (($value.StartsWith("'") -and $value.EndsWith("'")) -or ($value.StartsWith('"') -and $value.EndsWith('"'))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            [Environment]::SetEnvironmentVariable($name, $value)
        }
    }
}

function Get-Config {
    param([string]$SelectedEnvironment)

    $cfg = [ordered]@{
        Environment        = $SelectedEnvironment
        GoDaddyBaseUri     = if ($SelectedEnvironment -eq "ote") { "https://api.ote-godaddy.com" } else { "https://api.godaddy.com" }
        GoDaddyKey         = if ($SelectedEnvironment -eq "ote") { Get-RequiredEnv "GODADDY_OTE_KEY" } else { Get-RequiredEnv "GODADDY_PROD_KEY" }
        GoDaddySecret      = if ($SelectedEnvironment -eq "ote") { Get-RequiredEnv "GODADDY_OTE_SECRET" } else { Get-RequiredEnv "GODADDY_PROD_SECRET" }
        DmarcMailbox       = Get-RequiredEnv "DMARC_MAILBOX"
        ExcludedDomains    = Get-OptionalCsvEnv "EXCLUDED_DOMAINS"
        ParkedDomains      = Get-OptionalCsvEnv "PARKED_DOMAINS"
        SkipParkedDomains  = $true
        DefaultSpfValue    = "v=spf1 include:spf.protection.outlook.com -all"
        DefaultDmarcPolicy = "none"
        ApiRequestDelayMs  = 1100
    }

    $skipParkedRaw = [Environment]::GetEnvironmentVariable("SKIP_PARKED_DOMAINS")
    if (-not [string]::IsNullOrWhiteSpace($skipParkedRaw)) {
        $cfg.SkipParkedDomains = [System.Convert]::ToBoolean($skipParkedRaw)
    }
    $delayRaw = [Environment]::GetEnvironmentVariable("GODADDY_REQUEST_DELAY_MS")
    if (-not [string]::IsNullOrWhiteSpace($delayRaw)) {
        $parsedDelay = 0
        if ([int]::TryParse($delayRaw, [ref]$parsedDelay) -and $parsedDelay -ge 0) {
            $cfg.ApiRequestDelayMs = $parsedDelay
        }
    }
    return $cfg
}

function Get-LatestPlanFile {
    param([string]$Directory, [string]$EnvironmentName)
    if (-not (Test-Path -LiteralPath $Directory)) { return $null }

    Get-ChildItem -LiteralPath $Directory -Filter "plan-$EnvironmentName-*.json" -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

function Get-RequiredEnvNames {
    param([string]$SelectedEnvironment)
    $names = @("DMARC_MAILBOX")
    if ($SelectedEnvironment -eq "ote") {
        $names += @("GODADDY_OTE_KEY", "GODADDY_OTE_SECRET")
    } else {
        $names += @("GODADDY_PROD_KEY", "GODADDY_PROD_SECRET")
    }
    $names
}

function New-EnvCheckReport {
    param([string]$SelectedEnvironment)
    $required = Get-RequiredEnvNames -SelectedEnvironment $SelectedEnvironment
    $missing = @()
    foreach ($name in $required) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            $missing += $name
        }
    }
    [ordered]@{
        GeneratedAt  = (Get-Date).ToString("o")
        Environment  = $SelectedEnvironment
        Required     = $required
        Missing      = $missing
        IsConfigured = ($missing.Count -eq 0)
    }
}

function Write-EnvTemplate {
    param([string]$Path)

    $template = @(
        "# Required",
        "DMARC_MAILBOX=dmarc@example.com",
        "",
        "# GoDaddy OTE",
        "GODADDY_OTE_KEY=",
        "GODADDY_OTE_SECRET=",
        "",
        "# GoDaddy Production",
        "GODADDY_PROD_KEY=",
        "GODADDY_PROD_SECRET=",
        "",
        "# Optional",
        "EXCLUDED_DOMAINS=",
        "PARKED_DOMAINS=",
        "SKIP_PARKED_DOMAINS=true"
    )

    Set-Content -LiteralPath $Path -Value $template -Encoding UTF8
}

function Get-MaskedKey {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    if ($Value.Length -le 8) { return ("*" * $Value.Length) }
    $prefix = $Value.Substring(0, 4)
    $suffix = $Value.Substring($Value.Length - 4, 4)
    return "$prefix...$suffix"
}

function Get-GoDaddyHeaders {
    param($Config)
    @{
        Authorization = "sso-key $($Config.GoDaddyKey):$($Config.GoDaddySecret)"
        Accept        = "application/json"
        "Content-Type" = "application/json"
    }
}

function Invoke-GoDaddyApi {
    param(
        [string]$Method,
        [string]$Path,
        $Config,
        [object]$Body
    )

    $uri = "$($Config.GoDaddyBaseUri)$Path"
    $headers = Get-GoDaddyHeaders -Config $Config
    $maxAttempts = 6
    $attempt = 1
    $lastRequestAt = [Environment]::GetEnvironmentVariable("GODADDY_LAST_REQUEST_UTC", "Process")
    if (-not [string]::IsNullOrWhiteSpace($lastRequestAt) -and $Config.ApiRequestDelayMs -gt 0) {
        $lastUtc = [datetime]::Parse($lastRequestAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $elapsedMs = ((Get-Date).ToUniversalTime() - $lastUtc).TotalMilliseconds
        if ($elapsedMs -lt $Config.ApiRequestDelayMs) {
            $waitMs = [int][Math]::Ceiling($Config.ApiRequestDelayMs - $elapsedMs)
            Start-Sleep -Milliseconds $waitMs
        }
    }

    while ($true) {
        try {
            if ($null -eq $Body) {
                $result = Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
                [Environment]::SetEnvironmentVariable("GODADDY_LAST_REQUEST_UTC", (Get-Date).ToUniversalTime().ToString("o"), "Process")
                return $result
            }
            $isArrayBody = ($Body -is [System.Array]) -or ($Body -is [System.Collections.ArrayList])
            $jsonBody = if ($isArrayBody) {
                $Body | ConvertTo-Json -Depth 10 -AsArray
            } else {
                $Body | ConvertTo-Json -Depth 10
            }
            $result = Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $jsonBody
            [Environment]::SetEnvironmentVariable("GODADDY_LAST_REQUEST_UTC", (Get-Date).ToUniversalTime().ToString("o"), "Process")
            return $result
        } catch {
            $errorText = $_.Exception.Message
            $isTooManyRequests = $errorText -match "TOO_MANY_REQUESTS" -or $errorText -match "429"
            $isTransientServerError = $errorText -match "502" -or $errorText -match "503" -or $errorText -match "504" -or $errorText -match "timed out" -or $errorText -match "temporarily unavailable"
            if ($errorText -match "ACCESS_DENIED") {
                Write-Log "ACCESS_DENIED calling GoDaddy API: method=$Method path=$Path uri=$uri"
                Write-Log "Verify key/account permissions for this endpoint. If reseller, ensure X-Shopper-Id usage."
            }
            if ((-not $isTooManyRequests -and -not $isTransientServerError) -or $attempt -ge $maxAttempts) {
                throw
            }

            $retryAfterSec = 10
            $details = $_.ErrorDetails.Message
            if (-not [string]::IsNullOrWhiteSpace($details)) {
                try {
                    $parsed = $details | ConvertFrom-Json -ErrorAction Stop
                    if ($parsed.retryAfterSec -and [int]$parsed.retryAfterSec -gt 0) {
                        $retryAfterSec = [int]$parsed.retryAfterSec
                    }
                } catch {
                    if ($details -match "retry this request after waiting\s+(\d+)\s+seconds") {
                        $retryAfterSec = [int]$Matches[1]
                    }
                }
            }

            if ($isTooManyRequests) {
                Write-Log "GoDaddy rate limit hit for '$Path'. Waiting $retryAfterSec seconds before retry ($attempt/$maxAttempts)..."
            } else {
                # Exponential backoff for transient 5xx/server-side issues.
                $retryAfterSec = [Math]::Min([int][Math]::Pow(2, $attempt), 30)
                Write-Log "Transient GoDaddy API error for '$Path' ($errorText). Waiting $retryAfterSec seconds before retry ($attempt/$maxAttempts)..."
            }
            Start-Sleep -Seconds $retryAfterSec
            $attempt++
            [Environment]::SetEnvironmentVariable("GODADDY_LAST_REQUEST_UTC", (Get-Date).ToUniversalTime().ToString("o"), "Process")
        }
    }
}

function Get-GoDaddyDomains {
    param($Config)
    Invoke-GoDaddyApi -Method "GET" -Path "/v1/domains" -Config $Config -Body $null
}

function Get-GoDaddyRecord {
    param(
        [string]$Domain,
        [string]$Type,
        [string]$Name,
        $Config
    )
    try {
        Invoke-GoDaddyApi -Method "GET" -Path "/v1/domains/$Domain/records/$Type/$Name" -Config $Config -Body $null
    } catch {
        if ($_.Exception.Message -match "404") { return @() }
        throw
    }
}

function Set-GoDaddyRecord {
    param(
        [string]$Domain,
        [string]$Type,
        [string]$Name,
        [string]$Value,
        [int]$Ttl,
        $Config,
        [switch]$NoWrite
    )
    if ($NoWrite) { return }
    $body = @(@{ data = $Value; ttl = $Ttl })
    Invoke-GoDaddyApi -Method "PUT" -Path "/v1/domains/$Domain/records/$Type/$Name" -Config $Config -Body $body | Out-Null
}

function Connect-Exchange {
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        throw "Install ExchangeOnlineManagement first: Install-Module ExchangeOnlineManagement -Scope CurrentUser"
    }
    if (-not (Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue)) {
        Import-Module ExchangeOnlineManagement
    }
    if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
        try {
            Connect-ExchangeOnline -ShowBanner:$false
        } catch {
            if ($_.Exception.Message -match "window handle" -or $_.Exception.Message -match "WAM") {
                Write-Host "Interactive sign-in unavailable in this host. Falling back to device authentication..."
                Connect-ExchangeOnline -ShowBanner:$false -Device
            } else {
                throw
            }
        }
    }
}

function Get-DkimConfigForDomain {
    param([string]$Domain)
    $cfg = $null
    try {
        $cfg = Get-DkimSigningConfig -Identity $Domain -ErrorAction Stop
    } catch {
        # Some domains won't have a DKIM config yet; try to create one.
        try {
            New-DkimSigningConfig -DomainName $Domain -Enabled $false -ErrorAction Stop | Out-Null
            $cfg = Get-DkimSigningConfig -Identity $Domain -ErrorAction Stop
        } catch {
            throw "Unable to get or create DKIM config for '$Domain': $($_.Exception.Message)"
        }
    }

    if (-not $cfg) {
        throw "Unable to get or create DKIM config for '$Domain': empty response."
    }

    $cfgObj = @($cfg)[0]
    if ($null -eq $cfgObj -or -not $cfgObj.PSObject) {
        throw "Unexpected DKIM config response type for '$Domain'."
    }

    $propNames = @($cfgObj.PSObject.Properties.Name)
    if ($propNames.Count -eq 0) {
        throw "Unexpected DKIM config response shape for '$Domain': no properties."
    }
    if ($propNames -notcontains "Enabled" -or $propNames -notcontains "Status") {
        throw "Unexpected DKIM config response shape for '$Domain': missing Enabled/Status."
    }

    $enabled = [bool]$cfgObj.Enabled
    $status = [string]$cfgObj.Status
    $selector1 = if ($propNames -contains "Selector1CNAME") { [string]$cfgObj.Selector1CNAME } else { "" }
    $selector2 = if ($propNames -contains "Selector2CNAME") { [string]$cfgObj.Selector2CNAME } else { "" }

    [ordered]@{
        Domain         = $Domain
        Enabled        = $enabled
        Status         = $status
        Selector1CNAME = $selector1
        Selector2CNAME = $selector2
    }
}

function Get-DesiredDmarcValue {
    param([string]$Domain, [string]$Policy)
    "v=DMARC1; p=$Policy; rua=mailto:rua@$Domain; ruf=mailto:ruf@$Domain; fo=1; adkim=s; aspf=s; pct=100"
}

function Get-DesiredSpfValue {
    param(
        [string]$CurrentSpf,
        [string[]]$RequiredIncludes
    )

    $required = @($RequiredIncludes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($required.Count -eq 0) {
        $required = @("include:spf.protection.outlook.com")
    }
    $requiredJoined = ($required -join " ")

    if ([string]::IsNullOrWhiteSpace($CurrentSpf)) {
        return "v=spf1 $requiredJoined -all"
    }

    $trimmed = $CurrentSpf.Trim()
    if ($trimmed -notmatch "^v=spf1(\s|$)") {
        return "v=spf1 $requiredJoined -all"
    }

    $missingIncludes = @()
    foreach ($inc in $required) {
        if ($trimmed.ToLowerInvariant() -notmatch [regex]::Escape($inc.ToLowerInvariant())) {
            $missingIncludes += $inc
        }
    }
    if ($missingIncludes.Count -eq 0) {
        return $trimmed
    }

    $tokens = @($trimmed -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($tokens.Count -eq 0) {
        return "v=spf1 $requiredJoined -all"
    }

    $terminalTokenIndex = -1
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        if ($tokens[$i] -match "^[~\-\+\?]all$") {
            $terminalTokenIndex = $i
            break
        }
    }

    if ($terminalTokenIndex -ge 0) {
        if ($terminalTokenIndex -eq 0) {
            $after = @($tokens[$terminalTokenIndex..($tokens.Count - 1)])
            return "$($missingIncludes -join ' ') $($after -join ' ')"
        }
        $before = @($tokens[0..($terminalTokenIndex - 1)])
        $after = @($tokens[$terminalTokenIndex..($tokens.Count - 1)])
        return "$($before -join ' ') $($missingIncludes -join ' ') $($after -join ' ')"
    }

    return "$trimmed $($missingIncludes -join ' ')"
}

function Should-SkipDomain {
    param([string]$Domain, $Config)
    $d = $Domain.ToLowerInvariant()
    if ($Config.ExcludedDomains -contains $d) { return $true }
    if ($Config.SkipParkedDomains -and $Config.ParkedDomains -contains $d) { return $true }
    $false
}

function Get-RecordDataValue {
    param($Record)
    if ($null -eq $Record) { return "" }
    if ($Record -is [string]) { return $Record }
    if ($Record.PSObject.Properties.Name -contains "data") { return [string]$Record.data }
    if ($Record.PSObject.Properties.Name -contains "value") { return [string]$Record.value }
    if ($Record.PSObject.Properties.Name -contains "content") { return [string]$Record.content }
    return [string]$Record
}

function Get-DomainState {
    param([string]$Domain, $Config)
    $spf = @(Get-GoDaddyRecord -Domain $Domain -Type "TXT" -Name "@" -Config $Config) | Where-Object { (Get-RecordDataValue -Record $_) -like "v=spf1*" }
    $dmarc = Get-GoDaddyRecord -Domain $Domain -Type "TXT" -Name "_dmarc" -Config $Config
    $mx = Get-GoDaddyRecord -Domain $Domain -Type "MX" -Name "@" -Config $Config
    $dkim1 = Get-GoDaddyRecord -Domain $Domain -Type "CNAME" -Name "selector1._domainkey" -Config $Config
    $dkim2 = Get-GoDaddyRecord -Domain $Domain -Type "CNAME" -Name "selector2._domainkey" -Config $Config

    [ordered]@{
        Spf   = $spf
        Dmarc = $dmarc
        Mx    = $mx
        Dkim1 = $dkim1
        Dkim2 = $dkim2
    }
}

function Test-DomainHasMxRecord {
    param([string]$Domain, $Config)
    $mx = Get-GoDaddyRecord -Domain $Domain -Type "MX" -Name "@" -Config $Config
    (@($mx).Count -gt 0)
}

function New-PlanDocument {
    param($Config)
    Write-Log "Building plan for environment '$($Config.Environment)'..."
    Connect-Exchange
    $domains = Get-GoDaddyDomains -Config $Config
    Write-Log "GoDaddy returned $(@($domains).Count) domains for planning."
    $items = @()
    $dkimTargets = @()
    $aliasPlan = @()
    $processed = 0
    $skipped = 0
    $errors = @()

    foreach ($entry in $domains) {
        $domain = $entry.domain.ToLowerInvariant()
        if (Should-SkipDomain -Domain $domain -Config $Config) {
            $items += [ordered]@{ Domain = $domain; Skipped = $true; Reason = "ExcludedOrParked" }
            $skipped++
            continue
        }
        $processed++
        Write-Log "Planning domain: $domain"

        try {
            $state = Get-DomainState -Domain $domain -Config $Config

            $currentSpf = if (@($state.Spf).Count -gt 0) { Get-RecordDataValue -Record $state.Spf[0] } else { "" }
            $currentDmarc = if (@($state.Dmarc).Count -gt 0) { Get-RecordDataValue -Record $state.Dmarc[0] } else { "" }
            $currentDkim1 = if (@($state.Dkim1).Count -gt 0) { Get-RecordDataValue -Record $state.Dkim1[0] } else { "" }
            $currentDkim2 = if (@($state.Dkim2).Count -gt 0) { Get-RecordDataValue -Record $state.Dkim2[0] } else { "" }
            $hasMx = (@($state.Mx).Count -gt 0)

            $dkim = [ordered]@{
                Domain         = $domain
                Enabled        = $false
                Status         = if ($hasMx) { "Unknown" } else { "NoMxRecord" }
                Selector1CNAME = $currentDkim1
                Selector2CNAME = $currentDkim2
            }
            if ($hasMx) {
                $dkim = Get-DkimConfigForDomain -Domain $domain
                $dkimTargets += $dkim
            }

            $desiredSpf = if ($hasMx) {
                Get-DesiredSpfValue -CurrentSpf $currentSpf -RequiredIncludes @(
                    "include:spf.protection.outlook.com",
                    "include:spf.us.exclaimer.net"
                )
            } else {
                $currentSpf
            }
            $desiredDmarc = if ($hasMx) {
                Get-DesiredDmarcValue -Domain $domain -Policy $Config.DefaultDmarcPolicy
            } else {
                $currentDmarc
            }
            $desiredDkim1 = if ($hasMx) { $dkim.Selector1CNAME } else { $currentDkim1 }
            $desiredDkim2 = if ($hasMx) { $dkim.Selector2CNAME } else { $currentDkim2 }

            if ($hasMx) {
                $aliasPlan += [ordered]@{
                    Domain = $domain
                    Rua    = "rua@$domain"
                    Ruf    = "ruf@$domain"
                    Target = $Config.DmarcMailbox
                }
            }

            $items += [ordered]@{
                Domain = $domain
                Skipped = $false
                Current = [ordered]@{
                    Spf   = $currentSpf
                    Dmarc = $currentDmarc
                    Dkim1 = $currentDkim1
                    Dkim2 = $currentDkim2
                }
                Desired = [ordered]@{
                    Spf   = $desiredSpf
                    Dmarc = $desiredDmarc
                    Dkim1 = $desiredDkim1
                    Dkim2 = $desiredDkim2
                }
                Changes = [ordered]@{
                    SpfNeedsUpdate   = if ($hasMx) { ($currentSpf -ne $desiredSpf) } else { $false }
                    DmarcNeedsUpdate = if ($hasMx) { ($currentDmarc -ne $desiredDmarc) } else { $false }
                    Dkim1NeedsUpdate = if ($hasMx) { ($currentDkim1 -ne $desiredDkim1) } else { $false }
                    Dkim2NeedsUpdate = if ($hasMx) { ($currentDkim2 -ne $desiredDkim2) } else { $false }
                }
                HasMx            = $hasMx
                AliasesPlanned   = $hasMx
                NoMxSkipped      = (-not $hasMx)
            }
        } catch {
            $message = $_.Exception.Message
            Write-Log "Planning skip due to domain error: $domain :: $message"
            $errors += [ordered]@{
                Domain  = $domain
                Message = $message
            }
            $items += [ordered]@{
                Domain  = $domain
                Skipped = $true
                Reason  = "DomainError"
                Error   = $message
            }
        }
    }

    [ordered]@{
        GeneratedAt         = (Get-Date).ToString("o")
        Environment         = $Config.Environment
        RequireDkimApproval = $true
        DkimTargets         = $dkimTargets
        AliasPlan           = $aliasPlan
        Domains             = $items
        Summary             = [ordered]@{
            TotalReturned = @($domains).Count
            Processed     = $processed
            Skipped       = $skipped
            Errors        = @($errors).Count
        }
        Errors              = $errors
    }
}

function Write-Json {
    param([string]$Path, $Data)
    $Data | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $Path -Encoding UTF8
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Failed to write JSON file: $Path"
    }
    return (Resolve-AbsolutePath -Path $Path)
}

function New-ApiCheckReport {
    param($Config)
    $domains = @(Get-GoDaddyDomains -Config $Config)
    $sample = @($domains | Select-Object -First 3 | ForEach-Object { $_.domain })
    [ordered]@{
        GeneratedAt    = (Get-Date).ToString("o")
        Environment    = $Config.Environment
        BaseUri        = $Config.GoDaddyBaseUri
        AuthHeaderType = "sso-key"
        KeyMasked      = Get-MaskedKey -Value $Config.GoDaddyKey
        DomainCount    = $domains.Count
        SampleDomains  = $sample
    }
}

function Get-MailboxAliases {
    param([string]$Mailbox)
    $mbx = Get-Mailbox -Identity $Mailbox
    $mbx.EmailAddresses | ForEach-Object { $_.ToString().ToLowerInvariant() }
}

function Add-DmarcAliasesIfMissing {
    param(
        [string]$Mailbox,
        [string[]]$Aliases,
        [switch]$NoWrite
    )
    $existing = Get-MailboxAliases -Mailbox $Mailbox
    $missing = @()
    foreach ($alias in $Aliases) {
        $smtp = "smtp:$($alias.ToLowerInvariant())"
        if ($existing -notcontains $smtp) { $missing += $smtp }
    }
    if ($missing.Count -gt 0 -and -not $NoWrite) {
        Set-Mailbox -Identity $Mailbox -EmailAddresses @{ Add = $missing }
    }
    [ordered]@{
        MissingToAdd = $missing
    }
}

function Invoke-AliasPlan {
    param($Config)
    Write-Log "Starting alias plan for '$($Config.Environment)'..."
    Connect-Exchange
    $domains = Get-GoDaddyDomains -Config $Config
    Write-Log "GoDaddy returned $(@($domains).Count) domains for alias plan."
    $results = @()
    foreach ($entry in $domains) {
        $domain = $entry.domain.ToLowerInvariant()
        if (Should-SkipDomain -Domain $domain -Config $Config) { continue }
        try {
            if (-not (Test-DomainHasMxRecord -Domain $domain -Config $Config)) {
                Write-Log "Alias plan skip (no MX @ record): $domain"
                $results += [ordered]@{
                    Domain           = $domain
                    MissingAliases   = @()
                    SkippedNoMx      = $true
                }
                continue
            }
            $aliases = @("rua@$domain", "ruf@$domain")
            $check = Add-DmarcAliasesIfMissing -Mailbox $Config.DmarcMailbox -Aliases $aliases -NoWrite
            $results += [ordered]@{
                Domain = $domain
                MissingAliases = $check.MissingToAdd
                SkippedNoMx    = $false
            }
        } catch {
            $message = $_.Exception.Message
            Write-Log "Alias plan skipping domain due to API/Exchange error: $domain :: $message"
            $results += [ordered]@{
                Domain           = $domain
                MissingAliases   = @()
                SkippedNoMx      = $false
                SkippedError     = $true
                Error            = $message
            }
        }
    }
    $results
}

function Invoke-AliasApply {
    param($Config, [switch]$NoWrite)
    Write-Log "Starting alias apply for '$($Config.Environment)' (NoWrite=$NoWrite)..."
    Connect-Exchange
    $domains = Get-GoDaddyDomains -Config $Config
    Write-Log "GoDaddy returned $(@($domains).Count) domains for alias apply."
    $results = @()
    foreach ($entry in $domains) {
        $domain = $entry.domain.ToLowerInvariant()
        if (Should-SkipDomain -Domain $domain -Config $Config) { continue }
        try {
            if (-not (Test-DomainHasMxRecord -Domain $domain -Config $Config)) {
                Write-Log "Alias apply skip (no MX @ record): $domain"
                $results += [ordered]@{
                    Domain        = $domain
                    AddedAliases  = @()
                    Applied       = $false
                    SkippedNoMx   = $true
                }
                continue
            }
            $aliases = @("rua@$domain", "ruf@$domain")
            $apply = Add-DmarcAliasesIfMissing -Mailbox $Config.DmarcMailbox -Aliases $aliases -NoWrite:$NoWrite
            $results += [ordered]@{
                Domain = $domain
                AddedAliases = $apply.MissingToAdd
                Applied = (-not $NoWrite)
                SkippedNoMx = $false
            }
        } catch {
            $message = $_.Exception.Message
            Write-Log "Alias apply skipping domain due to Exchange error: $domain :: $message"
            $results += [ordered]@{
                Domain           = $domain
                AddedAliases     = @()
                Applied          = $false
                SkippedNoMx      = $false
                SkippedExoError  = $true
                Error            = $message
            }
        }
    }
    $results
}

function Invoke-ApplyPlan {
    param(
        $Config,
        [string]$PlanPath,
        [switch]$NoWrite,
        [switch]$EnableDkimSigning
    )
    if (-not (Test-Path -LiteralPath $PlanPath)) {
        throw "Plan file not found: $PlanPath"
    }

    Write-Log "Applying plan file: $PlanPath (NoWrite=$NoWrite, EnableDkimSigning=$EnableDkimSigning)"
    $plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
    Connect-Exchange
    $results = @()

    foreach ($item in $plan.Domains) {
        if ($item.Skipped) {
            $results += [ordered]@{ Domain = $item.Domain; Skipped = $true }
            continue
        }
        if (-not $item.HasMx) {
            Write-Log "Skipping apply for domain with no MX @ record: $($item.Domain)"
            $results += [ordered]@{
                Domain      = $item.Domain
                Skipped     = $true
                SkippedNoMx = $true
            }
            continue
        }
        Write-Log "Applying domain: $($item.Domain)"
        if ($item.Changes.SpfNeedsUpdate) {
            Set-GoDaddyRecord -Domain $item.Domain -Type "TXT" -Name "@" -Value $item.Desired.Spf -Ttl 600 -Config $Config -NoWrite:$NoWrite
            Write-Log "  SPF update queued/applied for $($item.Domain)"
        }
        if ($item.Changes.DmarcNeedsUpdate) {
            Set-GoDaddyRecord -Domain $item.Domain -Type "TXT" -Name "_dmarc" -Value $item.Desired.Dmarc -Ttl 600 -Config $Config -NoWrite:$NoWrite
            Write-Log "  DMARC update queued/applied for $($item.Domain)"
        }
        if ($item.Changes.Dkim1NeedsUpdate) {
            Set-GoDaddyRecord -Domain $item.Domain -Type "CNAME" -Name "selector1._domainkey" -Value $item.Desired.Dkim1 -Ttl 600 -Config $Config -NoWrite:$NoWrite
            Write-Log "  DKIM selector1 update queued/applied for $($item.Domain)"
        }
        if ($item.Changes.Dkim2NeedsUpdate) {
            Set-GoDaddyRecord -Domain $item.Domain -Type "CNAME" -Name "selector2._domainkey" -Value $item.Desired.Dkim2 -Ttl 600 -Config $Config -NoWrite:$NoWrite
            Write-Log "  DKIM selector2 update queued/applied for $($item.Domain)"
        }
        if ($EnableDkimSigning -and -not $NoWrite) {
            Set-DkimSigningConfig -Identity $item.Domain -Enabled $true
            Write-Log "  EXO DKIM signing enabled for $($item.Domain)"
        }
        $results += [ordered]@{
            Domain = $item.Domain
            Applied = (-not $NoWrite)
            DkimEnabledAttempted = [bool]$EnableDkimSigning
        }
    }
    $results
}

function New-StatusReport {
    param($Plan)
    $activeDomains = @($Plan.Domains | Where-Object { -not $_.Skipped })
    $spfUpdates = @($activeDomains | Where-Object { $_.Changes.SpfNeedsUpdate }).Count
    $dmarcUpdates = @($activeDomains | Where-Object { $_.Changes.DmarcNeedsUpdate }).Count
    $dkim1Updates = @($activeDomains | Where-Object { $_.Changes.Dkim1NeedsUpdate }).Count
    $dkim2Updates = @($activeDomains | Where-Object { $_.Changes.Dkim2NeedsUpdate }).Count
    $anyDnsUpdates = @($activeDomains | Where-Object {
        $_.Changes.SpfNeedsUpdate -or
        $_.Changes.DmarcNeedsUpdate -or
        $_.Changes.Dkim1NeedsUpdate -or
        $_.Changes.Dkim2NeedsUpdate
    }).Count

    [ordered]@{
        GeneratedAt = (Get-Date).ToString("o")
        Environment = $Plan.Environment
        Domains = [ordered]@{
            Total       = @($Plan.Domains).Count
            Active      = $activeDomains.Count
            Skipped     = @($Plan.Domains | Where-Object { $_.Skipped }).Count
            NeedsChange = $anyDnsUpdates
        }
        RequiredChanges = [ordered]@{
            Spf   = $spfUpdates
            Dmarc = $dmarcUpdates
            Dkim1 = $dkim1Updates
            Dkim2 = $dkim2Updates
        }
    }
}

function Invoke-Bootstrap {
    param(
        $Config,
        [string]$SelectedEnvironment,
        [string]$OutputPath,
        [string]$Timestamp,
        [switch]$NoWrite,
        [switch]$ApproveDkim,
        [switch]$EnableDkimSigning
    )

    Write-Log "Bootstrap started for '$SelectedEnvironment' (NoWrite=$NoWrite, ApproveDkim=$ApproveDkim, EnableDkimSigning=$EnableDkimSigning)"
    $plan = New-PlanDocument -Config $Config
    $planPath = Join-Path $OutputPath "plan-$SelectedEnvironment-$Timestamp.json"
    Write-Json -Path $planPath -Data $plan
    Write-Log "Bootstrap plan written: $planPath"

    $aliasResult = Invoke-AliasApply -Config $Config -NoWrite:$NoWrite
    Write-Log "Alias step completed."

    if (-not $NoWrite -and -not $ApproveDkim) {
        throw "Bootstrap blocked. Use -ApproveDkimTargets after you sanity-check derived DKIM targets."
    }

    $applyResult = Invoke-ApplyPlan -Config $Config -PlanPath $planPath -NoWrite:$NoWrite -EnableDkimSigning:$EnableDkimSigning
    Write-Log "Apply step completed."

    $verify = New-PlanDocument -Config $Config
    $verifyPath = Join-Path $OutputPath "verify-$SelectedEnvironment-$Timestamp.json"
    Write-Json -Path $verifyPath -Data $verify
    Write-Log "Verify step completed: $verifyPath"

    [ordered]@{
        GeneratedAt    = (Get-Date).ToString("o")
        Environment    = $SelectedEnvironment
        Applied        = (-not $NoWrite)
        PlanPath       = $planPath
        VerifyPath     = $verifyPath
        AliasesReport  = $aliasResult
        ApplyReport    = $applyResult
    }
}

$resolvedOutputDirectory = Resolve-AbsolutePath -Path $OutputDirectory
Ensure-Directory -Path $resolvedOutputDirectory
Import-DotEnv -Path $EnvFile
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

switch ($Command) {
    "inventory" {
        Write-Log "Command start: inventory ($TargetEnvironment)"
        $config = Get-Config -SelectedEnvironment $TargetEnvironment
        $domains = Get-GoDaddyDomains -Config $config
        Write-Log "GoDaddy returned $(@($domains).Count) domains for inventory."
        $data = @()
        $skipped = 0
        $errors = @()
        foreach ($entry in $domains) {
            $domain = $entry.domain.ToLowerInvariant()
            if (Should-SkipDomain -Domain $domain -Config $config) { $skipped++; continue }
            Write-Log "Inventory reading: $domain"
            try {
                $data += [ordered]@{
                    Domain = $domain
                    State  = Get-DomainState -Domain $domain -Config $config
                }
            } catch {
                $message = $_.Exception.Message
                Write-Log "Inventory skipping domain due to API error: $domain :: $message"
                $errors += [ordered]@{
                    Domain  = $domain
                    Message = $message
                }
            }
        }
        $path = Join-Path $resolvedOutputDirectory "inventory-$TargetEnvironment-$timestamp.json"
        $report = [ordered]@{
            GeneratedAt = (Get-Date).ToString("o")
            Environment = $TargetEnvironment
            Summary     = [ordered]@{
                TotalReturned = @($domains).Count
                Included      = @($data).Count
                Skipped       = $skipped
                Errors        = @($errors).Count
            }
            Domains = $data
            Errors  = $errors
        }
        $writtenPath = Write-Json -Path $path -Data $report
        Write-Host "Inventory report: $writtenPath"
        Write-Host "Inventory summary: total domains returned=$(@($domains).Count); included after filters=$(@($data).Count); skipped=$skipped; errors=$(@($errors).Count)"
    }
    "plan" {
        $config = Get-Config -SelectedEnvironment $TargetEnvironment
        $plan = New-PlanDocument -Config $config
        $path = Join-Path $resolvedOutputDirectory "plan-$TargetEnvironment-$timestamp.json"
        $writtenPath = Write-Json -Path $path -Data $plan
        Write-Host "Plan report: $writtenPath"
        Write-Host "Review DkimTargets and confirm, then run apply with -ApproveDkimTargets."
    }
    "status" {
        $config = Get-Config -SelectedEnvironment $TargetEnvironment
        $planSource = $null
        $plan = $null
        if (-not [string]::IsNullOrWhiteSpace($PlanFile)) {
            if (-not (Test-Path -LiteralPath $PlanFile)) {
                throw "Plan file not found: $PlanFile"
            }
            $plan = Get-Content -LiteralPath $PlanFile -Raw | ConvertFrom-Json
            $planSource = $PlanFile
        } else {
            $latestPlan = Get-LatestPlanFile -Directory $resolvedOutputDirectory -EnvironmentName $TargetEnvironment
            if ($latestPlan) {
                $plan = Get-Content -LiteralPath $latestPlan -Raw | ConvertFrom-Json
                $planSource = $latestPlan
            } else {
                $plan = New-PlanDocument -Config $config
                $planSource = "generated"
            }
        }

        $report = New-StatusReport -Plan $plan
        $report.PlanSource = $planSource
        $path = Join-Path $resolvedOutputDirectory "status-$TargetEnvironment-$timestamp.json"
        $writtenPath = Write-Json -Path $path -Data $report
        Write-Host "Status report: $writtenPath"
    }
    "env-template" {
        if (Test-Path -LiteralPath $EnvFile) {
            Write-Host "Env file already exists: $EnvFile"
        } else {
            Write-EnvTemplate -Path $EnvFile
            Write-Host "Created env template: $EnvFile"
        }
    }
    "env-check" {
        $report = New-EnvCheckReport -SelectedEnvironment $TargetEnvironment
        $path = Join-Path $resolvedOutputDirectory "env-check-$TargetEnvironment-$timestamp.json"
        $writtenPath = Write-Json -Path $path -Data $report
        Write-Host "Env check report: $writtenPath"
        if (-not $report.IsConfigured) {
            Write-Host "Missing required variables: $($report.Missing -join ', ')"
        }
    }
    "api-check" {
        $config = Get-Config -SelectedEnvironment $TargetEnvironment
        $report = New-ApiCheckReport -Config $config
        $path = Join-Path $resolvedOutputDirectory "api-check-$TargetEnvironment-$timestamp.json"
        $writtenPath = Write-Json -Path $path -Data $report
        Write-Host "API check report: $writtenPath"
        Write-Host "API check summary: env=$($report.Environment); base=$($report.BaseUri); domains=$($report.DomainCount); key=$($report.KeyMasked)"
    }
    "bootstrap" {
        $config = Get-Config -SelectedEnvironment $TargetEnvironment
        $report = Invoke-Bootstrap -Config $config -SelectedEnvironment $TargetEnvironment -OutputPath $resolvedOutputDirectory -Timestamp $timestamp -NoWrite:(-not $ApplyChanges) -ApproveDkim:$ApproveDkimTargets -EnableDkimSigning:$EnableDkim
        $path = Join-Path $resolvedOutputDirectory "bootstrap-$TargetEnvironment-$timestamp.json"
        $writtenPath = Write-Json -Path $path -Data $report
        Write-Host "Bootstrap report: $writtenPath"
        if (-not $ApplyChanges) {
            Write-Host "Dry-run only. Re-run with -ApplyChanges to write."
        }
    }
    "aliases-plan" {
        $config = Get-Config -SelectedEnvironment $TargetEnvironment
        $report = Invoke-AliasPlan -Config $config
        $path = Join-Path $resolvedOutputDirectory "aliases-plan-$TargetEnvironment-$timestamp.json"
        $writtenPath = Write-Json -Path $path -Data $report
        Write-Host "Alias plan report: $writtenPath"
    }
    "aliases-apply" {
        $config = Get-Config -SelectedEnvironment $TargetEnvironment
        $report = Invoke-AliasApply -Config $config -NoWrite:(-not $ApplyChanges)
        $path = Join-Path $resolvedOutputDirectory "aliases-apply-$TargetEnvironment-$timestamp.json"
        $writtenPath = Write-Json -Path $path -Data $report
        Write-Host "Alias apply report: $writtenPath"
        if (-not $ApplyChanges) {
            Write-Host "Dry-run only. Re-run with -ApplyChanges to write."
        }
    }
    "apply" {
        $config = Get-Config -SelectedEnvironment $TargetEnvironment
        if (-not $ApproveDkimTargets) {
            throw "Apply blocked. Use -ApproveDkimTargets after you sanity-check derived DKIM targets."
        }
        if ([string]::IsNullOrWhiteSpace($PlanFile)) {
            throw "Provide -PlanFile for apply."
        }
        $report = Invoke-ApplyPlan -Config $config -PlanPath $PlanFile -NoWrite:(-not $ApplyChanges) -EnableDkimSigning:$EnableDkim
        $path = Join-Path $resolvedOutputDirectory "apply-$TargetEnvironment-$timestamp.json"
        $writtenPath = Write-Json -Path $path -Data $report
        Write-Host "Apply report: $writtenPath"
        if (-not $ApplyChanges) {
            Write-Host "Dry-run only. Re-run with -ApplyChanges to write."
        }
    }
    "verify" {
        $config = Get-Config -SelectedEnvironment $TargetEnvironment
        $report = New-PlanDocument -Config $config
        $path = Join-Path $resolvedOutputDirectory "verify-$TargetEnvironment-$timestamp.json"
        $writtenPath = Write-Json -Path $path -Data $report
        Write-Host "Verify report: $writtenPath"
    }
}
