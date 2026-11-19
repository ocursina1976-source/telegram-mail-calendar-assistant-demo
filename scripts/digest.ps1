# Digest for the Telegram bot (read-only). Usage: digest.ps1 -Mode morning|evening|noon [-NoSend]
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less files as ANSI). Prompts live in prompts\*.txt (UTF-8).
param(
    [ValidateSet('morning', 'evening', 'noon')][string]$Mode = 'evening',
    [switch]$NoSend
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$logFile = Join-Path $PSScriptRoot 'digest.log'
function Write-Log($msg) {
    Add-Content -LiteralPath $logFile -Value ("{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Mode, $msg) -Encoding UTF8
}

$token = $null
function Hide-Token($s) { if ($token) { return ([string]$s).Replace($token, '***') } else { return [string]$s } }

function Send-Telegram($text) {
    $envFile = Join-Path $env:USERPROFILE '.claude\channels\telegram\.env'
    $line = Get-Content -LiteralPath $envFile | Where-Object { $_ -like 'TELEGRAM_BOT_TOKEN=*' } | Select-Object -First 1
    $script:token = ($line -replace '^TELEGRAM_BOT_TOKEN=', '').Trim().Trim('"').Trim("'")
    $access = Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.claude\channels\telegram\access.json') -Raw | ConvertFrom-Json
    $chat = $access.allowFrom[0]
    if (-not $token -or -not $chat) { throw 'telegram token or chat id not found' }
    # split by lines into chunks <= 3800 chars (Telegram limit is 4096)
    $chunks = @(); $cur = ''
    foreach ($ln in ($text -split "`r?`n")) {
        if (($cur.Length + $ln.Length + 1) -gt 3800 -and $cur.Length -gt 0) { $chunks += $cur; $cur = '' }
        $cur += $ln + "`n"
    }
    if ($cur.Trim().Length -gt 0) { $chunks += $cur }
    foreach ($c in $chunks) {
        $body = $utf8.GetBytes((@{ chat_id = $chat; text = $c.TrimEnd() } | ConvertTo-Json -Compress))
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post -ContentType 'application/json; charset=utf-8' -Body $body | Out-Null
    }
}

try {
    $claude = $null
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) { $claude = $cmd.Source }
    if (-not $claude) {
        $claude = (Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Filter claude.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    }
    if (-not $claude) { throw 'claude.exe not found' }

    $today = Get-Date
    $prompt = (Get-Content -LiteralPath (Join-Path $PSScriptRoot "prompts\$Mode.txt") -Raw -Encoding UTF8).
        Replace('{TODAY}', $today.ToString('yyyy-MM-dd')).
        Replace('{TOMORROW}', $today.AddDays(1).ToString('yyyy-MM-dd'))

    # read-only tools only; Telegram plugin disabled (a second poller would steal the bot's messages)
    $tools = 'mcp__yandex__accounts_list,mcp__yandex__mail_list_folders,mcp__yandex__mail_list_unread,mcp__yandex__mail_read,mcp__yandex__cal_list_calendars,mcp__yandex__cal_list_events,mcp__claude_ai_Google_Calendar__list_calendars,mcp__claude_ai_Google_Calendar__list_events,mcp__claude_ai_Google_Calendar__get_event'

    # cwd = scripts dir: parent CLAUDE.md files (07_Mail rules) load, project plugin settings of 07_Mail do not
    Set-Location -LiteralPath $PSScriptRoot
    Write-Log 'claude start'
    $out = $prompt | & $claude -p --model claude-sonnet-5-5 --settings (Join-Path $PSScriptRoot 'digest-settings.json') --allowedTools $tools --output-format text 2>&1 | Out-String
    $code = $LASTEXITCODE
    $out = $out.Trim()
    if ($code -ne 0 -or -not $out) { throw "claude failed, exit=$code" }
    Write-Log ("claude ok, {0} chars" -f $out.Length)

    if ($NoSend) { Write-Output $out } else { Send-Telegram $out; Write-Log 'sent to telegram' }
}
catch {
    $m = Hide-Token $_.Exception.Message
    Write-Log "ERROR: $m"
    if (-not $NoSend) {
        try { Send-Telegram ("Digest failed ($Mode): " + $m) } catch { Write-Log ('ERROR sending failure notice: ' + (Hide-Token $_.Exception.Message)) }
    }
    exit 1
}
