#requires -Version 5.1
<# Phase 3: run in the CURRENT PowerShell with & .\ilovetoken-setup.ps1.
   No API key parameter, telemetry, login, or interactive Codex launch.
   ASCII source is intentional for Windows PowerShell 5.1 compatibility. #>
[CmdletBinding()]
param()

function Split-ILTStatements {
    param([string]$Text)
    # Lexical statement boundaries; preserve comments and multiline strings verbatim.
    $start = 0; $quote = ''; $multi = $false; $depth = 0; $comment = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($comment) { if ($c -ne "`n") { continue }; $comment = $false }
        elseif ($quote) {
            if ($quote -eq '"' -and $c -eq '\') { $i++; continue }
            if ($c -eq $quote) {
                if (-not $multi) { $quote = '' }
                elseif ($i + 2 -lt $Text.Length -and $Text.Substring($i, 3) -eq ($quote * 3)) {
                    $i += 2
                    while ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq $quote) { $i++ }
                    $quote = ''; $multi = $false
                }
            }
            continue
        }
        elseif ($c -eq '#') { $comment = $true; continue }
        elseif ($c -eq '"' -or $c -eq "'") {
            $quote = [string]$c
            if ($i + 2 -lt $Text.Length -and $Text.Substring($i, 3) -eq ($quote * 3)) { $multi = $true; $i += 2 }
            continue
        }
        elseif ($c -eq '[' -or $c -eq '{') { $depth++ }
        elseif ($c -eq ']' -or $c -eq '}') { $depth--; if ($depth -lt 0) { throw 'Unbalanced TOML delimiters.' } }
        if ($c -eq "`n" -and $depth -eq 0) {
            $Text.Substring($start, $i - $start + 1); $start = $i + 1
        }
    }
    if ($quote -or $depth -ne 0) { throw 'Unterminated TOML value.' }
    if ($start -lt $Text.Length) { $Text.Substring($start) }
}

function Get-ILTKeyParts {
    param([string]$Text)
    $pattern = '\G\s*(?:([A-Za-z0-9_-]+)|"([^"\\]*)"|''([^'']*)'')\s*(\.|$)'
    $pos = 0
    do {
        $m = [regex]::Match($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(1))
        # Match against the remaining text so \G always starts at zero.
        if (-not $m.Success) { throw 'Unsupported TOML key syntax; original configuration is unchanged.' }
        if ($m.Groups[1].Success) { $m.Groups[1].Value }
        elseif ($m.Groups[2].Success) { $m.Groups[2].Value }
        else { $m.Groups[3].Value }
        $pos = $m.Length; $Text = $Text.Substring($pos)
        if ($m.Groups[4].Value -eq '.' -and $Text.Length -eq 0) { throw 'Invalid TOML dotted key.' }
    } while ($Text.Length -gt 0)
}

function Update-ILTConfig {
    param([AllowEmptyString()][string]$Text)
    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $body = New-Object System.Text.StringBuilder
    $extras = New-Object System.Text.StringBuilder
    $section = @(); $providerCount = 0; $rootCount = 0
    $activeMarker = ''; $seenMarkers = @{}
    $owned = @('name','base_url','env_key','wire_api','requires_openai_auth')
    foreach ($s in @(Split-ILTStatements $Text)) {
        $t = $s.Trim()
        if ($t -match '^# (BEGIN|END) ILOVETOKEN MANAGED (SELECTION|PROVIDER)$') {
            $kind = $Matches[1]; $label = $Matches[2]
            if ($kind -eq 'BEGIN') {
                if ($activeMarker -or $seenMarkers.ContainsKey($label)) { throw 'Duplicate or nested managed blocks.' }
                $activeMarker = $label; $seenMarkers[$label] = $true
            } else {
                if ($activeMarker -cne $label) { throw 'Unbalanced managed block markers.' }
                $activeMarker = ''
            }
            continue
        }
        if ($t.StartsWith('#') -and $t.Contains('ILOVETOKEN MANAGED')) { throw 'Unrecognized managed block marker.' }
        if ($t.StartsWith('[')) {
            if ($t -notmatch '^\[([^\r\n]+)\]\s*(?:#.*)?$') { throw 'Unsupported TOML table syntax.' }
            $header = $Matches[1]
            $arrayTable = $header.StartsWith('[') -and $header.EndsWith(']')
            if ($arrayTable) { $header = $header.Substring(1, $header.Length - 2) }
            $section = @(Get-ILTKeyParts $header)
            if ($section.Count -ge 2 -and $section[0] -ceq 'model_providers' -and $section[1] -ceq 'ilovetoken') {
                if ($arrayTable -or $section.Count -gt 2) { throw 'Nested ilovetoken provider tables require manual migration.' }
                $providerCount++; if ($providerCount -gt 1) { throw 'Duplicate ilovetoken provider table.' }
                continue
            }
            [void]$body.Append($s); continue
        }
        $isProvider = $section.Count -eq 2 -and $section[0] -ceq 'model_providers' -and $section[1] -ceq 'ilovetoken'
        if ($t -and -not $t.StartsWith('#')) {
            if ($t -notmatch '^((?:[^="'']|"[^"\\]*"|''[^'']*'')+)\s*=') { throw 'Unsupported TOML assignment.' }
            $parts = @(Get-ILTKeyParts $Matches[1])
            if ($section.Count -eq 0 -and $parts[0] -ceq 'model_provider') {
                $rootCount++; if ($parts.Count -ne 1 -or $rootCount -gt 1) { throw 'Ambiguous model_provider assignment.' }; continue
            }
            if (($section.Count -eq 0 -and $parts[0] -ceq 'model_providers') -or
                ($section.Count -eq 1 -and $section[0] -ceq 'model_providers' -and $parts[0] -ceq 'ilovetoken')) {
                throw 'Inline/dotted provider definitions require manual migration to [model_providers.ilovetoken].'
            }
            if ($isProvider) {
                if ($parts[0] -cin @('auth','experimental_bearer_token','http_headers','env_http_headers')) {
                    throw 'Existing ilovetoken authentication/header settings require manual migration.'
                }
                if ($parts[0] -cin $owned) {
                    if ($parts.Count -ne 1) { throw 'Unsupported provider field syntax.' }; continue
                }
            }
        }
        if ($isProvider) { [void]$extras.Append($s) } else { [void]$body.Append($s) }
    }
    if ($activeMarker) { throw 'Unterminated managed block.' }
    $selection = @('# BEGIN ILOVETOKEN MANAGED SELECTION','model_provider = "ilovetoken"','# END ILOVETOKEN MANAGED SELECTION') -join $nl
    $provider = @('# BEGIN ILOVETOKEN MANAGED PROVIDER','[model_providers.ilovetoken]','name = "ilovetoken"',
        'base_url = "https://api.ilovetoken.online/v1"','env_key = "ILOVETOKEN_API_KEY"','wire_api = "responses"','requires_openai_auth = false') -join $nl
    $middle = $body.ToString().Trim([char[]]"`r`n")
    $extra = $extras.ToString().Trim([char[]]"`r`n")
    $result = $selection + $nl
    if ($middle) { $result += $nl + $middle + $nl }
    $result += $nl + $provider + $nl
    if ($extra) { $result += $extra + $nl }
    return $result + '# END ILOVETOKEN MANAGED PROVIDER' + $nl
}

function Test-ILTModels {
    param([string]$Key)
    # No redirects, no response body/error dumping, no cookies or telemetry.
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false; $handler.UseCookies = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(20)
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, 'https://api.ilovetoken.online/v1/models')
    $response = $null
    try {
        $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Key)
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($status -ne 200) { Write-Warning "Models check: HTTP $status. Configuration saved; verify account/key/network, then rerun setup."; return }
        try {
            $data = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $data.PSObject.Properties['data'] -or $null -eq $data.data) { throw 'shape' }
            $modelCount = @($data.data).Count
            Write-Host ('Models check passed (HTTP 200; {0} models). This does not test Responses generation.' -f $modelCount)
        } catch { Write-Warning 'Models endpoint returned HTTP 200 but not the expected model-list JSON.' }
    } catch { Write-Warning 'Models check failed (network/TLS/timeout). Configuration saved; retry setup after checking connectivity.' }
    finally { if ($response) { $response.Dispose() }; $request.Dispose(); $client.Dispose(); $handler.Dispose(); $Key = $null }
}

function Normalize-ILTApiKey {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { throw 'No key was received.' }
    $normalized = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) { throw 'No key was received. Paste or type the key, then press Enter.' }
    if ($normalized.Length -gt 8192) { throw 'The key is unexpectedly long. Copy only the API key value.' }
    if ($normalized -match '\s') { throw 'The key contains whitespace. Copy only the API key value, without a variable name or quotes.' }
    return $normalized
}

function Read-ILTApiKey {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $secureInput = $null; $ptr = [IntPtr]::Zero; $candidate = $null
        try {
            $secureInput = Read-Host 'I Love Token API key' -AsSecureString
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureInput)
            $candidate = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
            return Normalize-ILTApiKey $candidate
        } catch {
            if ($attempt -ge 3) { throw 'No valid API key was entered after 3 attempts. Setup stopped without changing the key or configuration.' }
            Write-Warning ($_.Exception.Message + ' Try again; input remains hidden.')
        } finally {
            if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
            if ($secureInput) { $secureInput.Dispose() }
            $candidate = $null
        }
    }
}

function Invoke-ILTSetup {
    $ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) { throw '64-bit Windows is required.' }
    $configDir = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $env:USERPROFILE '.codex' } else { $env:CODEX_HOME }
    if (-not [IO.Path]::IsPathRooted($configDir)) { throw 'CODEX_HOME must be an absolute path.' }
    $configDir = [IO.Path]::GetFullPath($configDir)
    $configPath = Join-Path $configDir 'config.toml'
    [void][IO.Directory]::CreateDirectory($configDir)
    $lock = $null; $tempFile = $null; $stage = $null; $key = $null
    $oldTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        try { $lock = [IO.File]::Open((Join-Path $configDir '.ilovetoken-setup.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { throw 'Another setup is running, or the configuration directory is not writable.' }
        $exists = [IO.File]::Exists($configPath)
        [byte[]]$originalBytes = @()
        if ($exists) { $originalBytes = [IO.File]::ReadAllBytes($configPath) }
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $original = $utf8.GetString($originalBytes).TrimStart([char]0xFEFF)
        $updated = Update-ILTConfig $original
        Write-Host "Configuration: $configPath"
        [Net.ServicePointManager]::SecurityProtocol = $oldTls -bor [Net.SecurityProtocolType]::Tls12
        $tempFile = Join-Path ([IO.Path]::GetTempPath()) ('ilt-installer-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Invoke-WebRequest -UseBasicParsing -Uri 'https://download.ilovetoken.online/installer/codex-install.ps1' -OutFile $tempFile -TimeoutSec 60
        # The mirror sync verifies the official install.ps1 digest before publishing it,
        # then patches exactly one release-base URL. Do not pin this generated file's
        # hash here: its version header and upstream body legitimately change when
        # Codex releases. Reject truncated/non-PowerShell downloads before execution.
        if ((Get-Item -LiteralPath $tempFile).Length -lt 4096) { throw 'Downloaded mirror installer is unexpectedly small; no key has been requested.' }
        $installerTokens = $null; $installerErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($tempFile, [ref]$installerTokens, [ref]$installerErrors)
        if ($installerErrors.Count -gt 0) { throw 'Downloaded mirror installer is not valid PowerShell; no key has been requested.' }
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $PSHOME 'powershell.exe'
        if (-not [IO.File]::Exists($psi.FileName)) { $psi.FileName = Join-Path $PSHOME 'pwsh.exe' }
        $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $tempFile + '" -Release latest'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.EnvironmentVariables['CODEX_NON_INTERACTIVE'] = '1'
        $psi.EnvironmentVariables['CODEX_INSTALLER_USE_RELEASES_OPENAI_COM'] = '1'
        $psi.EnvironmentVariables.Remove('ILOVETOKEN_API_KEY')
        Write-Host 'Installing the unmodified Codex release through the verified mirror pipeline...'
        $process = [Diagnostics.Process]::Start($psi)
        try { $process.WaitForExit(); if ($process.ExitCode -ne 0) { throw 'Codex installation failed; key and config were not changed.' } }
        finally { $process.Dispose() }
        $binDir = if ([string]::IsNullOrWhiteSpace($env:CODEX_INSTALL_DIR)) { Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin' } else { $env:CODEX_INSTALL_DIR }
        if (-not [IO.Path]::IsPathRooted($binDir)) { throw 'CODEX_INSTALL_DIR must be an absolute path.' }
        $binDir = [IO.Path]::GetFullPath($binDir)
        $binary = Join-Path $binDir 'codex.exe'
        if (-not [IO.File]::Exists($binary)) { throw 'Installer returned without the expected codex.exe.' }
        $env:Path = $binDir + ';' + (($env:Path -split ';' | Where-Object { $_.TrimEnd('\') -ine $binDir.TrimEnd('\') }) -join ';')
        # Validate TOML with Codex itself in a temporary home; no interactive session.
        $stage = Join-Path $configDir ('ilt-validate-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($stage)
        [IO.File]::WriteAllText((Join-Path $stage 'config.toml'), $updated, $utf8)
        $validator = New-Object Diagnostics.ProcessStartInfo
        $validator.FileName = $binary; $validator.Arguments = 'features list'
        $validator.WorkingDirectory = $stage; $validator.UseShellExecute = $false; $validator.CreateNoWindow = $true
        $validator.RedirectStandardOutput = $true; $validator.RedirectStandardError = $true
        $validator.EnvironmentVariables['CODEX_HOME'] = $stage
        $validator.EnvironmentVariables.Remove('ILOVETOKEN_API_KEY')
        $p = [Diagnostics.Process]::Start($validator)
        try {
            $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit(30000)) { $p.Kill(); throw 'Configuration validation timed out; original config unchanged.' }
            if ($p.ExitCode -ne 0) { throw 'Codex rejected the proposed configuration; original config unchanged. Check existing configuration and retry.' }
        } finally { $p.Dispose() }
        Write-Host 'Enter your I Love Token API key locally. Input is hidden.'
        Write-Host 'It is stored in your Windows user environment and sent only to api.ilovetoken.online for the models check.'
        Write-Host 'Leading/trailing whitespace from the clipboard is removed automatically. You have up to 3 attempts.'
        $key = Read-ILTApiKey
        # Recheck before commit in case an editor changed the config during install.
        [byte[]]$current = @()
        if ([IO.File]::Exists($configPath)) { $current = [IO.File]::ReadAllBytes($configPath) }
        if ([IO.File]::Exists($configPath) -ne $exists -or [Convert]::ToBase64String($current) -cne [Convert]::ToBase64String($originalBytes)) { throw 'Configuration changed during setup. Rerun to merge the latest file.' }
        $updatedBytes = $utf8.GetBytes($updated)
        $configChanged = -not $exists -or [Convert]::ToBase64String($updatedBytes) -cne [Convert]::ToBase64String($originalBytes)
        $backup = $null
        if ($exists -and $configChanged) {
            $backup = $configPath + '.ilovetoken-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.bak'
            [IO.File]::WriteAllBytes($backup, $originalBytes)
            Write-Host "Original configuration backed up to: $backup"
        } elseif (-not $exists) {
            Write-Host 'No previous config.toml existed. Rollback: remove the newly created config.toml if it has no later edits.'
        } else {
            Write-Host 'Codex provider configuration is already current; no redundant backup was created.'
        }
        $oldUser = [Environment]::GetEnvironmentVariable('ILOVETOKEN_API_KEY','User')
        $oldProcess = [Environment]::GetEnvironmentVariable('ILOVETOKEN_API_KEY','Process')
        $saveStep = 'saving the Windows user environment variable'
        try {
            [Environment]::SetEnvironmentVariable('ILOVETOKEN_API_KEY',$key,'User')
            $saveStep = 'saving the current PowerShell environment variable'
            [Environment]::SetEnvironmentVariable('ILOVETOKEN_API_KEY',$key,'Process')
            if ($configChanged) {
                $saveStep = 'committing the Codex configuration'
                $candidate = Join-Path $stage 'config.toml'
                if ($exists) {
                    try {
                        # Prefer an atomic NTFS replace. Some Windows setups/filesystems reject
                        # File.Replace even though a normal overwrite is permitted.
                        [IO.File]::Replace($candidate, $configPath, $null)
                    } catch [System.IO.IOException] {
                        Write-Warning 'Atomic config replacement was unavailable; using the verified backup + overwrite fallback.'
                        [IO.File]::WriteAllBytes($configPath, $updatedBytes)
                    } catch [System.PlatformNotSupportedException] {
                        Write-Warning 'Atomic config replacement is not supported here; using the verified backup + overwrite fallback.'
                        [IO.File]::WriteAllBytes($configPath, $updatedBytes)
                    }
                } else {
                    [IO.File]::Move($candidate, $configPath)
                }
                $saveStep = 'verifying the saved Codex configuration'
                [byte[]]$savedBytes = [IO.File]::ReadAllBytes($configPath)
                if ([Convert]::ToBase64String($savedBytes) -cne [Convert]::ToBase64String($updatedBytes)) {
                    throw 'The saved config.toml did not match the validated configuration.'
                }
            }
        } catch {
            $saveError = $_.Exception
            $restoreNotes = New-Object System.Collections.Generic.List[string]
            try { [Environment]::SetEnvironmentVariable('ILOVETOKEN_API_KEY',$oldUser,'User') }
            catch { [void]$restoreNotes.Add('user environment rollback failed') }
            try { [Environment]::SetEnvironmentVariable('ILOVETOKEN_API_KEY',$oldProcess,'Process') }
            catch { [void]$restoreNotes.Add('process environment rollback failed') }
            if ($configChanged -and $exists -and $backup -and [IO.File]::Exists($backup)) {
                try { [IO.File]::Copy($backup, $configPath, $true) }
                catch { [void]$restoreNotes.Add('config rollback failed; use the printed .bak file manually') }
            } elseif ($configChanged -and -not $exists -and [IO.File]::Exists($configPath)) {
                try { [IO.File]::Delete($configPath) }
                catch { [void]$restoreNotes.Add('new config cleanup failed') }
            }
            $suffix = if ($restoreNotes.Count -gt 0) { ' Rollback note: ' + ($restoreNotes -join '; ') + '.' } else { ' Prior environment/configuration restored.' }
            throw ('Saving failed while {0}. {1}: {2}.{3} Keep the printed config backup for recovery.' -f $saveStep, $saveError.GetType().Name, $saveError.Message, $suffix)
        } finally { $oldUser = $null; $oldProcess = $null; $saveError = $null }
        Test-ILTModels $key
        Write-Host 'Setup complete. Codex was not opened. In your own project directory, run:'
        Write-Host '  cd C:\path\to\your-project'
        Write-Host '  codex'
    } finally {
        $key = $null
        [Net.ServicePointManager]::SecurityProtocol = $oldTls
        if ($tempFile -and [IO.File]::Exists($tempFile)) { [IO.File]::Delete($tempFile) }
        if ($stage -and [IO.Directory]::Exists($stage)) {
            $resolvedStage = [IO.Path]::GetFullPath($stage)
            if ($resolvedStage.StartsWith($configDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedStage -Leaf).StartsWith('ilt-validate-')) {
                Remove-Item -LiteralPath $resolvedStage -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if ($lock) { $lock.Dispose() }
    }
}

Invoke-ILTSetup
