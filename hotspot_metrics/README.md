# Hotspot Metrics

Containerized monitoring stack for Netgear hotspot cellular diagnostics.
Scrapes LTE/5G signal metrics from the hotspot admin page and visualizes them via a lightweight dashboard and Grafana.

## Architecture

```
┌──────────────┐     ┌────────────┐     ┌──────────┐     ┌───────────┐
│   Hotspot    │◄────│  Scraper   │────►│Prometheus│────►│  Grafana  │
│ 192.168.1.1  │     │(Playwright)│     │  :9090   │     │  :3000    │
└──────────────┘     └───:9100────┘     └────┬─────┘     └───────────┘
                                             │
                                     ┌───────┴───────┐     ┌──────────────┐
                                     │   Dashboard   │◄────│   Tunnel     │
                                     │ (nginx) :8080 │     │ (cloudflared)│
                                     └───────────────┘     └──────┬───────┘
                                                                  │
                                                          *.trycloudflare.com
```

### Services

| Container | Purpose | Port |
|-----------|---------|------|
| **scraper** | Python + Playwright headless browser. Logs into the hotspot admin page, navigates to diagnostics, extracts RF metrics, computes quality scores, and exposes Prometheus gauges. | `:9100` (host network) |
| **prometheus** | Scrapes the exporter every 15 seconds. | `:9090` |
| **grafana** | Full-featured dashboard with pre-provisioned panels. Anonymous viewer access enabled. | `:3000` |
| **dashboard** | Lightweight single-page HTML dashboard (~10KB) served via nginx, with Prometheus API proxy. Designed for constrained browsers (e.g., Tesla in-vehicle browser). | `:8080` |
| **tunnel** | Cloudflare quick tunnel. Exposes the lightweight dashboard via a public `*.trycloudflare.com` URL. No account required. | — |

## Metrics Exported

| Metric | Description |
|--------|-------------|
| `hotspot_lte_rsrp_dbm` | LTE Reference Signal Received Power |
| `hotspot_lte_rsrq_db` | LTE Reference Signal Received Quality |
| `hotspot_lte_snr_db` | LTE Signal-to-Noise Ratio |
| `hotspot_nr_rsrp_dbm` | 5G NR RSRP |
| `hotspot_nr_rsrq_db` | 5G NR RSRQ |
| `hotspot_nr_snr_db` | 5G NR SNR |
| `hotspot_lte_quality` | LTE composite quality score (0–100) |
| `hotspot_nr_quality` | 5G composite quality score (0–100) |
| `hotspot_service_type_info` | Current PS Service Type (e.g., 5GMMWAVE) |
| `hotspot_radio_band_info` | Current Radio Band |
| `hotspot_scrape_success` | Scrape health (1 = OK, 0 = fail) |
| `hotspot_exporter_heartbeat_unixtime` | Exporter loop heartbeat timestamp (unix seconds) |
| `hotspot_scrape_attempt_total` | Total scrape attempts |
| `hotspot_scrape_failure_total` | Total scrape failures |

## Quick Start

### Prerequisites

- [Podman](https://podman.io/) and `podman-compose` installed
- Your machine must be on the hotspot's local network (192.168.1.1 reachable)

### Setup

1. **Copy and configure environment:**

   ```sh
   cp .env.example .env
   # Edit .env with your hotspot admin password
   ```

2. **Build and start the stack:**

   ```sh
   podman compose -f podman-compose.yml up -d --build
   ```

3. **Access the dashboards:**

   - **Grafana** (full): [http://localhost:3000](http://localhost:3000) — anonymous viewer access enabled; log in with `admin` / `admin` (or your `.env` values) to edit.
   - **Lightweight dashboard**: [http://localhost:8080](http://localhost:8080) — single-page HTML, ideal for constrained browsers.
   - **Tunnel (remote access)**: Check the public URL with:

     ```sh
     podman logs hotspot-tunnel 2>&1 | grep trycloudflare.com
     ```

     The tunnel URL changes on each container restart. It provides access to the lightweight dashboard via a public `*.trycloudflare.com` URL — useful for devices that block private IP addresses (e.g., Tesla in-vehicle browser).

### Stopping

```sh
podman compose -f podman-compose.yml down
```

### Rebuilding the scraper

```sh
podman compose -f podman-compose.yml build scraper
podman compose -f podman-compose.yml up -d scraper
```

## Configuration

All settings are controlled via environment variables (set in `.env`):

| Variable | Default | Description |
|----------|---------|-------------|
| `HOTSPOT_URL` | `http://192.168.1.1` | Hotspot admin URL |
| `HOTSPOT_USERNAME` | `admin` | Login username |
| `HOTSPOT_PASSWORD` | *(required)* | Login password |
| `SCRAPE_INTERVAL` | `15` | Seconds between scrapes |
| `GRAFANA_USER` | `admin` | Grafana admin username |
| `GRAFANA_PASSWORD` | `admin` | Grafana admin password |
| `CLOUDFLARE_TUNNEL_TOKEN` | *(empty)* | Token for a named Cloudflare tunnel (stable URL) |
| `TUNNEL_CMD` | `tunnel --no-autoupdate --url http://dashboard:8080` | Tunnel command override (set for named tunnels) |

## Dashboards

### Grafana (full)

Available at [http://localhost:3000](http://localhost:3000). Includes:

- **Time-series chart**: LTE (blue) and 5G (pink) quality scores 0–100, matching the original userscript visualization
- **Service Type**: Current PS Service Type (e.g., 5GMMWAVE, LTE)
- **Radio Band**: Current active radio band
- **Gauge panels**: Individual RSRP, RSRQ, SNR for both LTE and 5G with color-coded thresholds (green/yellow/red)

Anonymous viewer access is enabled. Sign in as admin to edit.

### Lightweight HTML Dashboard

Available at [http://localhost:8080](http://localhost:8080) and via the Cloudflare tunnel URL. A single ~10KB HTML page with:

- LTE and 5G quality scores with color-coded values
- 30-minute quality time-series chart (canvas-based, no dependencies)
- Individual RSRP, RSRQ, SNR gauges for both LTE and 5G
- Live scrape-age indicator and stale-data warning
- Auto-refresh every 5 seconds

Designed for constrained browsers where Grafana's 10MB JS payload is too heavy (e.g., Tesla in-vehicle browser, low-bandwidth connections).

## Cloudflare Tunnel

The `tunnel` service exposes the lightweight dashboard via a public URL. Two modes are supported:

### Quick Tunnel (default, no account)

Works out of the box. The URL is random and changes on each restart.

```sh
# Check the current URL
podman logs hotspot-tunnel 2>&1 | grep trycloudflare.com
```

### Named Tunnel (stable URL, free account)

For a persistent URL, create a free [Cloudflare](https://dash.cloudflare.com) account:

1. Go to **Zero Trust → Networks → Tunnels → Create a tunnel**
2. Name it (e.g., `hotspot-metrics`) and copy the tunnel token
3. Configure the tunnel's public hostname to point to `http://dashboard:8080`
4. Add to your `.env`:

   ```sh
   CLOUDFLARE_TUNNEL_TOKEN=eyJh...your_token...
   TUNNEL_CMD=tunnel --no-autoupdate run --token eyJh...your_token...
   ```

5. Restart the tunnel: `podman compose -f podman-compose.yml up -d tunnel`

### Notes

- All data collection remains local; only the dashboard viewing path traverses the tunnel
- The tunnel auto-reconnects after network interruptions
- When connectivity drops, the last-loaded dashboard state remains visible in the browser

## Troubleshooting

- **Scraper can't reach hotspot**: The scraper uses `network_mode: host` to access the LAN. Ensure 192.168.1.1 is reachable from the host.
- **Login fails**: Check credentials in `.env`. The scraper uses Netgear-specific selectors (`#session_password`, `#login_submit`).
- **No data in Grafana**: Check scraper logs with `podman compose -f podman-compose.yml logs scraper`. Verify Prometheus targets at `http://localhost:9090/targets`.
- **All metrics showing None**: The scraper auto-recovers after 5 consecutive empty scrapes by restarting the browser session. If the issue persists, restart the scraper: `podman compose -f podman-compose.yml restart scraper`.
- **Tunnel URL not working**: The URL changes on restart. Check the current one: `podman logs hotspot-tunnel 2>&1 | grep trycloudflare.com`.
- **Podman ports only on localhost (Windows/WSL)**: Podman on Windows binds ports to `127.0.0.1` regardless of `0.0.0.0` in compose. Use `netsh interface portproxy` to expose to the LAN:

  ```powershell
  # Run as Administrator
  netsh interface portproxy add v4tov4 listenport=8080 listenaddress=0.0.0.0 connectport=8080 connectaddress=127.0.0.1
  ```
