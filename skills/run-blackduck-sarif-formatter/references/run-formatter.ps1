<#
.SYNOPSIS
  Run blackduck-sarif-formatter's full-scan script with the URL trailing slash
  stripped and the API token read from a blackduck-c-cpp config.yaml (so the
  token never appears literally in your command line).

.EXAMPLE
  .\run-formatter.ps1 -Config C:\path\config.yaml -Project curl -Version 8.4.0 `
      -Formatter C:\src\blackduck-sarif-formatter\blackduckResultsToSarif.py `
      -Python    C:\path\.venv\Scripts\python.exe `
      -OutputFile C:\out\curl-8.4.0.sarif.json
#>
param(
  [Parameter(Mandatory)] [string]$Config,       # blackduck-c-cpp config.yaml (has bd_url + api_token)
  [Parameter(Mandatory)] [string]$Project,
  [Parameter(Mandatory)] [string]$Version,
  [Parameter(Mandatory)] [string]$Formatter,    # path to blackduckResultsToSarif.py
  [string]$Python = "python",
  [string]$OutputFile = "$PWD\blackduck.sarif.json",
  [string]$PolicyCategories = "SECURITY",
  [string]$LogLevel = "INFO"
)

# --- pull bd_url + api_token out of the config (simple key: value lines) ---
$url   = (Select-String -Path $Config -Pattern '^\s*bd_url:\s*(.+)$').Matches.Groups[1].Value.Trim()
$token = (Select-String -Path $Config -Pattern '^\s*api_token:\s*(.+)$').Matches.Groups[1].Value.Trim()

if (-not $url)   { throw "bd_url not found in $Config" }
if (-not $token) { throw "api_token not found in $Config" }

# --- CRITICAL: strip the trailing slash, or HubInstance builds host//api/... -> 400 -> KeyError x-csrf-token ---
$url = $url.TrimEnd('/')

# --- run from an empty dir so the formatter's cwd fallback walk stays cheap ---
$work = Join-Path $env:TEMP ("bd-sarif-" + [System.Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
Push-Location $work
try {
  & $Python $Formatter `
      --url $url `
      --token $token `
      --project $Project `
      --version $Version `
      --policyCategories $PolicyCategories `
      --outputFile $OutputFile `
      --log_level $LogLevel
  Write-Host "formatter exit code: $LASTEXITCODE"
}
finally {
  Pop-Location
}
