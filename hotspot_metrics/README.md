# Hotspot Metrics

Containerized monitoring stack for Netgear hotspot cellular diagnostics.
Scrapes LTE/5G signal metrics from the hotspot admin page and visualizes them in Grafana.

## Architecture

```
┌──────────────┐     ┌────────────┐     ┌─────────┐
│  Hotspot      │◄────│  Scraper   │────►│Prometheus│────►│ Grafana │
│ 192.168.1.1  │     │ (Playwright)│     │  :9090   │     │  :3000  │
└──────────────┘     └─────:9100───┘     └──────────┘     └─────────┘
```

- **Scraper**: Python + Playwright headless browser. Logs into the hotspot admin page, navigates to diagnostics, extracts RF metrics, computes quality scores, and exposes Prometheus gauges on `:9100/metrics`.
- **Prometheus**: Scrapes the exporter every 15 seconds.
- **Grafana**: Pre-provisioned dashboard with time-series quality chart, service type display, and per-metric gauges.

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

3. **Open Grafana:**

   Navigate to [http://localhost:3000](http://localhost:3000) and log in with `admin` / `admin` (or whatever you set in `.env`).

   The **Hotspot Cellular Diagnostics** dashboard is pre-provisioned and should start populating within ~30 seconds.

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

## Dashboard

The Grafana dashboard includes:

- **Time-series chart**: LTE (blue) and 5G (pink) quality scores 0–100, matching the original userscript visualization
- **Service Type**: Current PS Service Type (e.g., 5GMMWAVE, LTE)
- **Radio Band**: Current active radio band
- **Gauge panels**: Individual RSRP, RSRQ, SNR for both LTE and 5G with color-coded thresholds (green/yellow/red)

## Troubleshooting

- **Scraper can't reach hotspot**: The scraper uses `network_mode: host` to access the LAN. Ensure 192.168.1.1 is reachable from the host.
- **Login fails**: Check credentials in `.env`. The scraper looks for `input[type="password"]` on the page.
- **No data in Grafana**: Check scraper logs with `podman compose -f podman-compose.yml logs scraper`. Verify Prometheus targets at `http://localhost:9090/targets`.
