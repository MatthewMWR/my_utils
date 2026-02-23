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
    "hotspot-prometheus",
    "hotspot-dashboard",
    "hotspot-tunnel"
)

$missing = @($required | Where-Object { $_ -notin $runningContainers })
if ($missing.Count -gt 0) {
    Fail "Required containers not running: $($missing -join ', ')"
}
Write-Ok "All required containers are running."

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

$heartbeatRaw = curl.exe -s -m $TimeoutSeconds "http://localhost:8080/api/v1/query?query=hotspot_exporter_heartbeat_unixtime"
try {
    $heartbeat = $heartbeatRaw | ConvertFrom-Json
} catch {
    Fail "Heartbeat query returned invalid JSON."
}

if ($heartbeat.status -ne "success" -or $heartbeat.data.result.Count -lt 1) {
    Fail "Heartbeat metric missing from Prometheus proxy response."
}

$heartbeatUnix = [double]$heartbeat.data.result[0].value[1]
$nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$heartbeatAge = [int][Math]::Round($nowUnix - $heartbeatUnix)

if ($heartbeatAge -le 20) {
    Write-Ok "Heartbeat is fresh (${heartbeatAge}s old)."
} else {
    Write-Warn "Heartbeat is stale (${heartbeatAge}s old). Scraper may be blocked."
}

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
