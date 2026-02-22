"""Netgear hotspot cellular diagnostics scraper → Prometheus exporter."""

import logging
import os
import re
import time

from prometheus_client import Counter, Gauge, Info, start_http_server
from playwright.sync_api import sync_playwright, TimeoutError as PwTimeout

# --------------- Config ---------------
HOTSPOT_URL = os.getenv("HOTSPOT_URL", "http://192.168.1.1")
DIAG_HASH = "settings/diagnostics"
USERNAME = os.getenv("HOTSPOT_USERNAME", "admin")
PASSWORD = os.getenv("HOTSPOT_PASSWORD", "")
SCRAPE_INTERVAL = int(os.getenv("SCRAPE_INTERVAL", "15"))
METRICS_PORT = int(os.getenv("METRICS_PORT", "9100"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("hotspot-scraper")

# --------------- Prometheus metrics ---------------
LTE_RSRP = Gauge("hotspot_lte_rsrp_dbm", "LTE RSRP in dBm")
LTE_RSRQ = Gauge("hotspot_lte_rsrq_db", "LTE RSRQ in dB")
LTE_SNR = Gauge("hotspot_lte_snr_db", "LTE RS-SNR in dB")

NR_RSRP = Gauge("hotspot_nr_rsrp_dbm", "5G NR RSRP in dBm")
NR_RSRQ = Gauge("hotspot_nr_rsrq_db", "5G NR RSRQ in dB")
NR_SNR = Gauge("hotspot_nr_snr_db", "5G NR RS-SNR in dB")

LTE_QUALITY = Gauge("hotspot_lte_quality", "LTE composite quality score 0-100")
NR_QUALITY = Gauge("hotspot_nr_quality", "5G NR composite quality score 0-100")

SERVICE_TYPE = Info("hotspot_service_type", "Current PS Service Type")
RADIO_BAND = Info("hotspot_radio_band", "Current Radio Band")

SCRAPE_SUCCESS = Gauge("hotspot_scrape_success", "1 if last scrape succeeded, 0 otherwise")
EXPORTER_HEARTBEAT_UNIXTIME = Gauge(
    "hotspot_exporter_heartbeat_unixtime",
    "Unix timestamp of last successful exporter loop heartbeat",
)
SCRAPE_ATTEMPT_TOTAL = Counter("hotspot_scrape_attempt_total", "Total scrape attempts")
SCRAPE_FAILURE_TOTAL = Counter("hotspot_scrape_failure_total", "Total scrape failures")

# --------------- Metric extraction (ported from userscript) ---------------

def extract_metric(text: str, label: str, unit: str) -> float | None:
    pattern = rf"{re.escape(label)}\s*(-?\d+(?:\.\d+)?)\s*{re.escape(unit)}"
    m = re.search(pattern, text)
    return float(m.group(1)) if m else None


def extract_string(text: str, label: str) -> str:
    pattern = rf"{re.escape(label)}\s*([^\n\r]+)"
    m = re.search(pattern, text)
    return m.group(1).strip() if m else ""


def clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def quality_score(snr: float | None, rsrq: float | None, rsrp: float | None) -> float | None:
    """Weighted composite quality 0-100, matching userscript logic."""
    parts = []
    if snr is not None:
        parts.append((clamp((snr + 5) / 25, 0, 1), 0.50))
    if rsrq is not None:
        parts.append((clamp((rsrq + 20) / 17, 0, 1), 0.30))
    if rsrp is not None:
        parts.append((clamp((rsrp + 120) / 40, 0, 1), 0.20))
    if not parts:
        return None
    wsum = sum(w for _, w in parts)
    vsum = sum(v * w for v, w in parts)
    return round((vsum / wsum) * 100)


def parse_diagnostics(text: str) -> dict:
    """Extract all metrics from the diagnostics page text."""
    return {
        "lte_rsrp": extract_metric(text, "LTE RSRP", "dBm"),
        "lte_rsrq": extract_metric(text, "LTE RSRQ", "dB"),
        "lte_snr": extract_metric(text, "LTE RS-SNR", "dB"),
        "nr_rsrp": extract_metric(text, "5G RSRP", "dBm"),
        "nr_rsrq": extract_metric(text, "5G RSRQ", "dB"),
        "nr_snr": extract_metric(text, "5G RS-SNR", "dB"),
        "band": extract_string(text, "Current Radio Band"),
        "service_type": extract_string(text, "PS Service Type"),
    }


def update_gauges(data: dict):
    """Push parsed data into Prometheus gauges."""

    def _set(gauge, val):
        if val is not None:
            gauge.set(val)

    _set(LTE_RSRP, data["lte_rsrp"])
    _set(LTE_RSRQ, data["lte_rsrq"])
    _set(LTE_SNR, data["lte_snr"])
    _set(NR_RSRP, data["nr_rsrp"])
    _set(NR_RSRQ, data["nr_rsrq"])
    _set(NR_SNR, data["nr_snr"])

    lte_q = quality_score(data["lte_snr"], data["lte_rsrq"], data["lte_rsrp"])
    nr_q = quality_score(data["nr_snr"], data["nr_rsrq"], data["nr_rsrp"])
    _set(LTE_QUALITY, lte_q)
    _set(NR_QUALITY, nr_q)

    if data["service_type"]:
        SERVICE_TYPE.info({"type": data["service_type"]})
    if data["band"]:
        RADIO_BAND.info({"band": data["band"]})

    SCRAPE_SUCCESS.set(1)
    log.info(
        "LTE q=%s (RSRP=%s RSRQ=%s SNR=%s) | 5G q=%s (RSRP=%s RSRQ=%s SNR=%s) | %s • %s",
        lte_q, data["lte_rsrp"], data["lte_rsrq"], data["lte_snr"],
        nr_q, data["nr_rsrp"], data["nr_rsrq"], data["nr_snr"],
        data["band"], data["service_type"],
    )


# --------------- Browser automation ---------------

class HotspotScraper:
    def __init__(self):
        self._pw = None
        self._browser = None
        self._page = None

    def start(self):
        self._pw = sync_playwright().start()
        try:
            self._browser = self._pw.chromium.launch(headless=True)
            self._page = self._browser.new_page()
            self._login()
        except Exception:
            self.stop()
            raise

    def _login(self):
        log.info("Logging in to %s …", HOTSPOT_URL)
        self._page.goto(HOTSPOT_URL, wait_until="networkidle", timeout=30_000)
        time.sleep(2)  # let SPA hydrate

        # Attempt form login — look for password field
        try:
            pw_input = self._page.wait_for_selector(
                'input[type="password"]', timeout=10_000
            )
            # Fill username if present
            user_input = self._page.query_selector('input[type="text"], input[name="username"]')
            if user_input:
                user_input.fill(USERNAME)
            pw_input.fill(PASSWORD)

            # Click submit button
            submit = self._page.query_selector(
                'button[type="submit"], input[type="submit"], button:has-text("Sign In"), button:has-text("Login"), button:has-text("Log In")'
            )
            if submit:
                submit.click()
            else:
                pw_input.press("Enter")

            self._page.wait_for_load_state("networkidle", timeout=15_000)
            time.sleep(2)
            log.info("Login completed.")
        except PwTimeout:
            log.warning("No password field found — may already be logged in.")

    def _navigate_to_diagnostics(self):
        target = f"{HOTSPOT_URL}/index.html#{DIAG_HASH}"
        if self._page.url != target:
            self._page.goto(target, wait_until="networkidle", timeout=20_000)
        else:
            self._page.reload(wait_until="networkidle", timeout=20_000)
        time.sleep(2)  # let SPA render diagnostics

    def _is_login_page(self) -> bool:
        """Detect if we've been redirected back to login."""
        return self._page.query_selector('input[type="password"]') is not None

    def scrape(self) -> str | None:
        """Navigate to diagnostics and return page text, re-auth if needed."""
        try:
            self._navigate_to_diagnostics()

            if self._is_login_page():
                log.info("Session expired, re-authenticating…")
                self._login()
                self._navigate_to_diagnostics()

            text = self._page.inner_text("body")
            return text
        except Exception:
            log.exception("Scrape failed")
            return None

    def stop(self):
        if self._browser:
            self._browser.close()
        if self._pw:
            self._pw.stop()


# --------------- Main loop ---------------

def run():
    log.info("Starting Prometheus metrics server on :%d", METRICS_PORT)
    start_http_server(METRICS_PORT)

    log.info("Scraping every %ds …", SCRAPE_INTERVAL)
    scraper = None
    try:
        while True:
            EXPORTER_HEARTBEAT_UNIXTIME.set(time.time())
            SCRAPE_ATTEMPT_TOTAL.inc()
            if scraper is None:
                try:
                    scraper = HotspotScraper()
                    scraper.start()
                except Exception:
                    SCRAPE_SUCCESS.set(0)
                    SCRAPE_FAILURE_TOTAL.inc()
                    log.exception("Failed to initialize scraper, retrying in %ds", SCRAPE_INTERVAL)
                    scraper = None
                    time.sleep(SCRAPE_INTERVAL)
                    continue

            text = scraper.scrape()
            if text:
                data = parse_diagnostics(text)
                update_gauges(data)
            else:
                SCRAPE_SUCCESS.set(0)
                SCRAPE_FAILURE_TOTAL.inc()
                log.warning("Scrape returned no data")
            time.sleep(SCRAPE_INTERVAL)
    except KeyboardInterrupt:
        log.info("Shutting down…")
    finally:
        if scraper is not None:
            scraper.stop()


if __name__ == "__main__":
    run()
