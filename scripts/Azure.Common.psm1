#Requires -Version 7.2
Set-StrictMode -Version Latest

function Assert-RetailEnvironmentName {
    <#
    .SYNOPSIS
    Reject unsafe environment identifiers before resolving local or Azure paths.
    #>
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -cnotmatch '^[a-z][a-z0-9]{2,11}$') {
        throw 'EnvironmentName must be 3-12 lowercase letters and digits, starting with a letter.'
    }
}

function Get-RetailTokenActor {
    <#
    .SYNOPSIS
    Read actor metadata from an ARM token obtained directly from trusted Azure CLI.
    .DESCRIPTION
    This is not token authentication. Azure validates the token on requests;
    Activity Log remains the authority for the identity that performed an action.
    #>
    param([Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][guid]$TenantId)
    $parts = $AccessToken.Split('.')
    if ($parts.Count -ne 3) { throw 'Malformed operator token.' }
    $encoded = $parts[1].Replace('-', '+').Replace('_', '/')
    $encoded = $encoded.PadRight($encoded.Length + (4 - $encoded.Length % 4) % 4, '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) |
        ConvertFrom-Json -AsHashtable
    if ($claims.tid -ine $TenantId.ToString() -or
        $claims.aud.TrimEnd('/') -cne 'https://management.azure.com') { throw 'Wrong presenter token context.' }
    return ([guid]$claims.oid).ToString()
}

function Invoke-RetailAzure {
    <#
    .SYNOPSIS
    Run Azure CLI with explicit subscription and native argument-array handling.
    .DESCRIPTION
    On Windows bypass the cmd launcher so REST query characters remain data.
    Return parsed JSON; propagate CLI failures without printing argument secrets.
    .PARAMETER SubscriptionId
    The explicit authorized subscription.
    .PARAMETER Arguments
    Individual CLI arguments, not a shell command.
    .PARAMETER TimeoutSeconds
    Optional process deadline. Zero preserves the caller's existing unbounded behavior.
    .EXAMPLE
    Invoke-RetailAzure -SubscriptionId <guid> -Arguments @('account', 'show')
    .OUTPUTS
    Parsed JSON objects.
    #>
    param(
        [Parameter(Mandatory)][guid]$SubscriptionId,
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 0
    )
    $executable = (Get-Command az -ErrorAction Stop).Source
    $prefix = @()
    if ($IsWindows -and [IO.Path]::GetExtension($executable) -eq '.cmd') {
        $executable = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $executable) '..\python.exe'))
        if (-not (Test-Path -LiteralPath $executable)) { throw 'Azure CLI Python launcher is unavailable.' }
        $prefix = @('-IBm', 'azure.cli')
    }
    $operation = $Arguments[0..([Math]::Min(1, $Arguments.Count - 1))] -join ' '
    if ($TimeoutSeconds -gt 0) {
        $startInfo = [Diagnostics.ProcessStartInfo]::new($executable)
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @($prefix) + @($Arguments) +
            @('--subscription', $SubscriptionId.ToString(), '--only-show-errors', '--output', 'json')) {
            $startInfo.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            $null = $process.Start()
            $process.StandardInput.Close()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                throw [TimeoutException]::new("Azure CLI timed out after $TimeoutSeconds seconds: $operation. An Azure operation may still be in progress.")
            }
            $result = $stdout.GetAwaiter().GetResult()
            $null = $stderr.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) { throw "Azure CLI failed: $operation. Inspect Azure operation status; arguments and error payload were withheld." }
        } finally { $process.Dispose() }
    } else {
        $result = & $executable @prefix @Arguments --subscription $SubscriptionId.ToString() --only-show-errors --output json
        if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $operation." }
    }
    if ($result) { return (($result -join "`n") | ConvertFrom-Json -AsHashtable) }
}

function Save-RetailState {
    <#
    .SYNOPSIS
    Atomically persist only non-secret deployment state.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Path)
    $State | ConvertTo-Json -Depth 40 |
        Set-Content -LiteralPath "$Path.tmp" -Encoding utf8NoBOM
    Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force
}

function ConvertTo-RetailGuestPayload {
    <#
    .SYNOPSIS
    Encode non-secret JSON for a shell-independent, bounded guest command.
    #>
    param([Parameter(Mandatory)][hashtable]$Value)
    $json = $Value | ConvertTo-Json -Depth 30 -Compress
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

Export-ModuleMember -Function Assert-RetailEnvironmentName, Save-RetailState,
    ConvertTo-RetailGuestPayload, Invoke-RetailAzure, Get-RetailTokenActor
