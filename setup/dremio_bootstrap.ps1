# Provision the demo Dremio instance without typing in the UI.
#
# Creates the local `admin123` user through the first-user bootstrap endpoint and
# the `nessie` source through the catalog API, using the settings documented in
# AGENTS.md and README.md. Idempotent: a second run creates nothing.
#
# Called by Start Demo.bat after Dremio answers on :9047 and before the browser
# tabs open, so the UI never races the API.
#
# The endpoint shapes are pinned to Dremio 26.0.5 and were verified live:
#   PUT  /apiv2/bootstrap/firstuser   (POST returns 405; Allow header says PUT)
#   POST /apiv2/login                 -> short-lived token, header _dremio<token>
#   GET  /api/v3/catalog/by-path/nessie -> 404 when absent
#   POST /api/v3/catalog              -> source entity; config keys below
#
# Demo credentials are fixed so nothing has to be looked up on stage:
#   user admin123 / password admin123 - the same word for both
# Dremio requires 8+ characters with at least one digit, so plain 'admin' is
# rejected (verified) while admin123 is accepted. A pre-existing .env can
# override either value.
#
# Exit codes: 0 = provisioned or already provisioned, 1 = could not provision.

$ErrorActionPreference = 'Stop'

$baseUri = 'http://localhost:9047'
$projectRoot = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $projectRoot '.env'

function Write-Note([string]$text) { Write-Host "      $text" }

function Read-DotEnv {
    $values = @{}
    if (Test-Path -LiteralPath $envFile) {
        foreach ($line in (Get-Content -LiteralPath $envFile)) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
                $values[$matches[1]] = $matches[2]
            }
        }
    }
    return $values
}

function Add-DotEnvLine([string]$name, [string]$value) {
    $prefix = ''
    if ((Test-Path -LiteralPath $envFile) -and (Get-Item -LiteralPath $envFile).Length -gt 0) {
        $prefix = "`r`n"
    }
    Add-Content -LiteralPath $envFile -Value "$prefix$name=$value" -NoNewline
}

function Get-HttpStatus($errorRecord) {
    if ($errorRecord.Exception.Response) {
        return [int]$errorRecord.Exception.Response.StatusCode
    }
    return $null
}

function Get-ErrorBody($errorRecord) {
    try {
        $stream = $errorRecord.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
        $reader.Close()
        return $text
    } catch {
        return ''
    }
}

# --- credentials -------------------------------------------------------------
# Fixed demo credentials: admin123 / admin123. Values already in .env win, which
# is how a machine with an older password keeps working without a reset.
$envValues = Read-DotEnv
$user = $envValues['DREMIO_USER']
if (-not $user) { $user = 'admin123' }

$password = $envValues['DREMIO_PASSWORD']
$chosenHere = $false
if (-not $password) {
    $password = 'admin123'
    $chosenHere = $true
}

$awsKey = $envValues['MINIO_ROOT_USER']
if (-not $awsKey) { $awsKey = 'minioadmin' }
$awsSecret = $envValues['MINIO_ROOT_PASSWORD']
if (-not $awsSecret) { $awsSecret = 'minioadmin' }

# --- wait for the REST API, not just the open port ---------------------------
# The port opens and the server answers HTTP well before it can accept writes;
# an early bootstrap attempt is rejected. A 401 on an unauthenticated catalog
# read is the verified "ready" signal (it replaced the raced 400 response).
$apiReady = $false
for ($i = 0; $i -lt 150; $i++) {
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$baseUri/api/v3/catalog" -TimeoutSec 3 | Out-Null
        $apiReady = $true
        break
    } catch {
        if ((Get-HttpStatus $_) -eq 401) { $apiReady = $true; break }
    }
    Start-Sleep -Seconds 2
}
if (-not $apiReady) {
    Write-Note "Dremio REST API did not answer at $baseUri - skipping provisioning."
    exit 1
}

function Get-DremioToken([string]$name, [string]$secret) {
    try {
        $body = @{ userName = $name; password = $secret } | ConvertTo-Json
        $response = Invoke-RestMethod -Method Post -Uri "$baseUri/apiv2/login" `
            -Body $body -ContentType 'application/json' -TimeoutSec 30
        return $response.token
    } catch {
        return $null
    }
}

function New-DremioFirstUser([string]$name, [string]$secret) {
    $body = @{
        userName  = $name
        firstName = 'Lakehouse'
        lastName  = 'Admin'
        email     = 'admin123@lakehouse.local'
        password  = $secret
    } | ConvertTo-Json
    try {
        Invoke-RestMethod -Method Put -Uri "$baseUri/apiv2/bootstrap/firstuser" `
            -Body $body -ContentType 'application/json' -TimeoutSec 120 | Out-Null
        return $true
    } catch {
        $status = Get-HttpStatus $_
        Write-Note "First-user bootstrap refused (HTTP $status) - a user may already exist."
        return $false
    }
}

# --- user --------------------------------------------------------------------
# Log in first: if the account is there, nothing is created and nothing changes.
$token = $null
if (-not $chosenHere) {
    $token = Get-DremioToken $user $password
}
if (-not $token) {
    if (New-DremioFirstUser $user $password) {
        Write-Note "Created the Dremio user '$user'."
        if ($chosenHere) {
            Add-DotEnvLine 'DREMIO_USER' $user
            Add-DotEnvLine 'DREMIO_PASSWORD' $password
            Write-Note "Saved DREMIO_USER / DREMIO_PASSWORD to .env (git-ignored)."
            Write-Note "Tableau password: $password"
        }
        $token = Get-DremioToken $user $password
    } else {
        Write-Note "A Dremio user exists but the .env password does not match it."
        Write-Note "Set DREMIO_PASSWORD in .env to that password, or run Reset Demo.bat."
        exit 0
    }
}
if (-not $token) {
    Write-Note "Could not log in to Dremio as '$user' - skipping the Nessie source."
    exit 1
}

# --- Nessie source -----------------------------------------------------------
$headers = @{ Authorization = "_dremio$token" }

$sourceExists = $false
try {
    Invoke-RestMethod -Method Get -Uri "$baseUri/api/v3/catalog/by-path/nessie" `
        -Headers $headers -TimeoutSec 30 | Out-Null
    $sourceExists = $true
} catch {
    $status = Get-HttpStatus $_
    if ($status -ne 404 -and $status -ne 400) {
        Write-Note "Could not check the Nessie source (HTTP $status) - skipping it."
        exit 1
    }
}

if ($sourceExists) {
    Write-Note "The Nessie source already exists - nothing to do."
    exit 0
}

$payload = @{
    entityType = 'source'
    name       = 'nessie'
    type       = 'NESSIE'
    config     = @{
        nessieEndpoint  = 'http://nessie:19120/api/v2'
        nessieAuthType  = 'NONE'
        storageProvider = 'AWS'
        credentialType  = 'ACCESS_KEY'
        awsAccessKey    = $awsKey
        awsAccessSecret = $awsSecret
        awsRootPath     = 'warehouse'
        secure          = $false
        propertyList     = @(
            @{ name = 'fs.s3a.path.style.access'; value = 'true' },
            @{ name = 'fs.s3a.endpoint'; value = 'minio:9000' },
            @{ name = 'dremio.s3.compat'; value = 'true' }
        )
    }
} | ConvertTo-Json -Depth 8

try {
    Invoke-RestMethod -Method Post -Uri "$baseUri/api/v3/catalog" `
        -Headers $headers -Body $payload -ContentType 'application/json' -TimeoutSec 180 | Out-Null
    Write-Note "Created the Nessie source. Dremio is ready - just log in as '$user'."
    exit 0
} catch {
    $status = Get-HttpStatus $_
    Write-Note "Could not create the Nessie source (HTTP $status)."
    $detail = Get-ErrorBody $_
    if ($detail) { Write-Note $detail }
    Write-Note "Add it by hand with the steps in README.md."
    exit 1
}
