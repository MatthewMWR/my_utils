param(
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = "Stop"

function Write-Ok([string]$Message) {
    Write-Host "[ok] $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "[warn] $Message" -ForegroundColor Yellow
}

function Fail([string]$Message) {
    Write-Host "[fail] $Message" -ForegroundColor Red
    exit 1
}

$machineText = podman machine list 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Fail "Podman machine status check failed: $machineText"
}
if (-not ($machineText | Select-String "Currently running")) {
    Fail "Podman machine is not running."
}
Write-Ok "Podman machine is running."

$runningContainers = @(podman ps --format "{{.Names}}" 2>$null)
$required = @(
    "hotspot-scraper",
    "hotspot-dashboard",
    "hotspot-tunnel"
)

$missing = @($required | Where-Object { $_ -notin $runningContainers })
if ($missing.Count -gt 0) {
    Fail "Required containers not running: $($missing -join ', ')"
}
Write-Ok "All required containers are running."

$prometheusRunning = "hotspot-prometheus" -in $runningContainers
if ($prometheusRunning) {
    $promCode = curl.exe -s -m $TimeoutSeconds -o NUL -w "%{http_code}" http://localhost:9090/-/ready
    if ($promCode -eq "200") {
        Write-Ok "Prometheus endpoint is reachable."
    } else {
        Write-Warn "Prometheus container is running but readiness endpoint returned HTTP $promCode."
    }
} else {
    Write-Warn "Prometheus is in standby (optional). Enable with: podman compose -f podman-compose.yml --profile observability up -d prometheus"
}

$grafanaRunning = "hotspot-grafana" -in $runningContainers
if ($grafanaRunning) {
    $grafanaCode = curl.exe -s -m $TimeoutSeconds -o NUL -w "%{http_code}" http://localhost:3000/
    if ($grafanaCode -eq "200" -or $grafanaCode -eq "302") {
        Write-Ok "Grafana endpoint is reachable."
    } else {
        Write-Warn "Grafana container is running but endpoint returned HTTP $grafanaCode."
    }
} else {
    Write-Warn "Grafana is in standby (not running by default). Enable with: podman compose -f podman-compose.yml --profile grafana up -d grafana"
}

$dashboardCode = curl.exe -s -m $TimeoutSeconds -o NUL -w "%{http_code}" http://localhost:8080/
if ($dashboardCode -ne "200") {
    Fail "Dashboard check failed (HTTP $dashboardCode)."
}
Write-Ok "Dashboard endpoint is reachable."

$snapshot = $null
$lastSnapshotIssue = "snapshot endpoint did not return data"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

do {
    $snapshotRaw = curl.exe -s -m $TimeoutSeconds "http://localhost:8080/snapshot"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($snapshotRaw)) {
        $lastSnapshotIssue = "snapshot endpoint returned no data"
        Start-Sleep -Seconds 2
        continue
    }

    try {
        $snapshot = $snapshotRaw | ConvertFrom-Json
    } catch {
        $lastSnapshotIssue = "snapshot endpoint returned invalid JSON"
        Start-Sleep -Seconds 2
        continue
    }

    if ($null -eq $snapshot.heartbeat_unixtime) {
        $lastSnapshotIssue = "snapshot payload is missing heartbeat_unixtime"
        Start-Sleep -Seconds 2
        continue
    }

    break
} while ((Get-Date) -lt $deadline)

if ($null -eq $snapshot -or $null -eq $snapshot.heartbeat_unixtime) {
    Fail "Snapshot endpoint not ready within ${TimeoutSeconds}s ($lastSnapshotIssue)."
}

$heartbeatUnix = [double]$snapshot.heartbeat_unixtime
$nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$heartbeatAge = [int][Math]::Round($nowUnix - $heartbeatUnix)

if ($heartbeatAge -le 20) {
    Write-Ok "Snapshot heartbeat is fresh (${heartbeatAge}s old)."
} else {
    Write-Warn "Snapshot heartbeat is stale (${heartbeatAge}s old). Scraper may be blocked."
}

$historyRaw = curl.exe -s -m $TimeoutSeconds "http://localhost:8080/history?seconds=300"
try {
    $history = $historyRaw | ConvertFrom-Json
} catch {
    Fail "History endpoint returned invalid JSON."
}
if ($null -eq $history.points) {
    Fail "History endpoint did not return a points array."
}
Write-Ok "History endpoint returned $($history.points.Count) point(s)."

$sseFirstLine = curl.exe -s -m $TimeoutSeconds -N http://localhost:8080/events | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($sseFirstLine)) {
    Fail "SSE stream produced no keepalive/data within ${TimeoutSeconds}s."
}
if ($sseFirstLine -match "^(data:|: keepalive)") {
    Write-Ok "SSE endpoint is streaming (${sseFirstLine})."
} else {
    Write-Warn "SSE first line was unexpected: ${sseFirstLine}"
}

$portProxyText = netsh interface portproxy show v4tov4 | Out-String
if ($portProxyText | Select-String "0\.0\.0\.0") {
    Write-Warn "Portproxy rules exist. Keep only required rules to avoid Podman port-binding conflicts."
} else {
    Write-Ok "No portproxy rules detected."
}

Write-Host ""
Write-Host "Sanity check complete." -ForegroundColor Cyan
