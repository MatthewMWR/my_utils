"""Netgear hotspot cellular diagnostics scraper → Prometheus exporter."""

import json
import logging
import os
import queue
import re
import threading
import time

from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from prometheus_client import Counter, Gauge, Info, start_http_server
from playwright.sync_api import sync_playwright, TimeoutError as PwTimeout

# --------------- Config ---------------
HOTSPOT_URL = os.getenv("HOTSPOT_URL", "http://192.168.1.1")
DIAG_HASH = "settings/diagnostics"
USERNAME = os.getenv("HOTSPOT_USERNAME", "admin")
PASSWORD = os.getenv("HOTSPOT_PASSWORD", "")
SCRAPE_INTERVAL = int(os.getenv("SCRAPE_INTERVAL", "5"))
METRICS_PORT = int(os.getenv("METRICS_PORT", "9100"))
SSE_PORT = int(os.getenv("SSE_PORT", "9101"))

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
SOURCE_STATE_CODE = Gauge(
    "hotspot_source_state_code",
    "Source state code (0=ok,1=no_signal,2=source_unavailable,3=parse_warning,4=scrape_error,5=startup_error)",
)
SOURCE_EMPTY_STREAK = Gauge(
    "hotspot_source_empty_streak",
    "Consecutive scrapes with unavailable diagnostics content",
)
SOURCE_STATUS = Info("hotspot_source_status", "Current scraper source status details")
LAST_SCRAPE_UNIXTIME = Gauge(
    "hotspot_last_scrape_unixtime",
    "Unix timestamp of last completed scrape parse/update",
)

SOURCE_STATE_CODES = {
    "ok": 0,
    "no_signal": 1,
    "source_unavailable": 2,
    "parse_warning": 3,
    "scrape_error": 4,
    "startup_error": 5,
}

NUMERIC_FIELDS = (
    "lte_rsrp", "lte_rsrq", "lte_snr",
    "nr_rsrp", "nr_rsrq", "nr_snr",
)

# --------------- SSE broadcast ---------------


class SSEBroadcaster:
    """Thread-safe Server-Sent Events broadcaster."""

    def __init__(self):
        self._clients: list[queue.Queue] = []
        self._lock = threading.Lock()

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=8)
        with self._lock:
            self._clients.append(q)
        return q

    def unsubscribe(self, q: queue.Queue):
        with self._lock:
            self._clients = [c for c in self._clients if c is not q]

    def broadcast(self, data: dict):
        payload = json.dumps(data)
        with self._lock:
            for q in self._clients:
                try:
                    q.put_nowait(payload)
                except queue.Full:
                    pass  # slow client, drop event


sse_broadcaster = SSEBroadcaster()


class _SSEHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path != "/events":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        q = sse_broadcaster.subscribe()
        try:
            while True:
                try:
                    payload = q.get(timeout=15)
                    self.wfile.write(f"data: {payload}\n\n".encode())
                    self.wfile.flush()
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            sse_broadcaster.unsubscribe(q)

    def log_message(self, format, *args):
        pass


def _start_sse_server():
    server = ThreadingHTTPServer(("", SSE_PORT), _SSEHandler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    log.info("SSE server listening on :%d/events", SSE_PORT)

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


def empty_diagnostics() -> dict:
    """Return an empty diagnostics payload used for error states."""
    return {
        "lte_rsrp": None,
        "lte_rsrq": None,
        "lte_snr": None,
        "nr_rsrp": None,
        "nr_rsrq": None,
        "nr_snr": None,
        "band": "",
        "service_type": "",
    }


def classify_source_state(text: str, data: dict) -> tuple[str, str]:
    """Classify scraper state so offline/auth issues are not confused with parser issues."""
    parsed_numeric = sum(1 for key in NUMERIC_FIELDS if data[key] is not None)
    if parsed_numeric > 0 or data["band"] or data["service_type"]:
        return "ok", "diagnostics updated"

    lower = text.lower()
    diagnostics_labels = (
        "lte rsrp",
        "lte rsrq",
        "lte rs-snr",
        "5g rsrp",
        "5g rsrq",
        "5g rs-snr",
        "current radio band",
        "ps service type",
    )
    labels_present = any(label in lower for label in diagnostics_labels)
    if labels_present and "n/a" in lower:
        return "no_signal", "diagnostics report n/a values"
    if labels_present:
        return "parse_warning", "diagnostics labels found but no parseable values"
    return "source_unavailable", "diagnostics content missing (offline/auth/session)"


def _extract_metric_value(raw: object) -> tuple[float | None, bool, bool]:
    """
    Parse a numeric metric value from raw model payload values.
    Returns (value, sentinel_seen, malformed_seen).
    """
    if raw is None:
        return None, False, False

    if isinstance(raw, (int, float)):
        num = float(raw)
    elif isinstance(raw, str):
        text = raw.strip()
        if not text:
            return None, False, False
        m = re.search(r"-?\d+(?:\.\d+)?", text)
        if not m:
            return None, False, True
        num = float(m.group(0))
    else:
        return None, False, True

    # Netgear sentinel values for unavailable/invalid metrics.
    if num in (-32768.0, -3276.0, 32767.0, 3276.0):
        return None, True, False
    if num < -300 or num > 300:
        return None, True, False
    return num, False, False


def _pick_metric(*candidates: object) -> tuple[float | None, bool, bool]:
    sentinel_seen = False
    malformed_seen = False
    for raw in candidates:
        value, sentinel, malformed = _extract_metric_value(raw)
        sentinel_seen = sentinel_seen or sentinel
        malformed_seen = malformed_seen or malformed
        if value is not None:
            return value, sentinel_seen, malformed_seen
    return None, sentinel_seen, malformed_seen


def parse_model_payload(model: dict) -> tuple[dict, str, str]:
    """Parse diagnostics directly from /api/model.json payloads."""
    if not isinstance(model, dict):
        return empty_diagnostics(), "source_unavailable", "model payload invalid"

    wwan = model.get("wwan")
    if not isinstance(wwan, dict):
        return empty_diagnostics(), "source_unavailable", "model payload missing wwan section"

    signal = wwan.get("signalStrength")
    if not isinstance(signal, dict):
        signal = {}

    diag_info = wwan.get("diagInfo")
    diag0 = diag_info[0] if isinstance(diag_info, list) and diag_info and isinstance(diag_info[0], dict) else {}

    lte_rsrp, s1, m1 = _pick_metric(diag0.get("ltesigRsrp"), signal.get("rsrp"), signal.get("lteRsrp"))
    lte_rsrq, s2, m2 = _pick_metric(diag0.get("ltesigRsrq"), signal.get("rsrq"), signal.get("lteRsrq"))
    lte_snr, s3, m3 = _pick_metric(diag0.get("ltesigSnr"), signal.get("snr"), signal.get("lteSnr"))

    nr_rsrp, s4, m4 = _pick_metric(diag0.get("nr5gsigRsrp"), signal.get("nr5gRsrp"), signal.get("nr5gRSRP"))
    nr_rsrq, s5, m5 = _pick_metric(diag0.get("nr5gsigRsrq"), signal.get("nr5gRsrq"), signal.get("nr5gRSRQ"))
    nr_snr, s6, m6 = _pick_metric(diag0.get("nr5gsigSnr"), signal.get("nr5gSnr"), signal.get("nr5gSNR"))

    sentinel_seen = any((s1, s2, s3, s4, s5, s6))
    malformed_seen = any((m1, m2, m3, m4, m5, m6))

    wwanadv = model.get("wwanadv")
    band = ""
    if isinstance(wwanadv, dict):
        band = str(wwanadv.get("curBand", "")).strip()
    if not band:
        band = str(wwan.get("curBand", "")).strip()

    service_type = str(wwan.get("currentPSserviceType", "")).strip()
    if not service_type:
        service_type = str(wwan.get("currentNWserviceType", "")).strip()

    data = {
        "lte_rsrp": lte_rsrp,
        "lte_rsrq": lte_rsrq,
        "lte_snr": lte_snr,
        "nr_rsrp": nr_rsrp,
        "nr_rsrq": nr_rsrq,
        "nr_snr": nr_snr,
        "band": band,
        "service_type": service_type,
    }

    parsed_numeric = sum(1 for key in NUMERIC_FIELDS if data[key] is not None)
    if parsed_numeric > 0 or band or service_type:
        return data, "ok", "model stream updated"
    if sentinel_seen and not malformed_seen:
        return data, "no_signal", "model stream reports no signal"
    if malformed_seen:
        return data, "parse_warning", "model stream values not parseable"
    if signal or diag0:
        return data, "source_unavailable", "model stream has no diagnostics values"
    return data, "source_unavailable", "model payload missing diagnostics sections"


def set_source_state(state: str, message: str, empty_streak: int):
    SOURCE_STATE_CODE.set(SOURCE_STATE_CODES[state])
    SOURCE_EMPTY_STREAK.set(empty_streak)
    SOURCE_STATUS.info({"state": state, "message": message})


def update_gauges(
    data: dict,
    source_state: str,
    source_message: str,
    empty_streak: int,
    heartbeat_unixtime: float,
) -> dict:
    """Push parsed data into Prometheus gauges. Returns SSE-ready payload."""

    def _set(gauge, val):
        gauge.set(val if val is not None else float("nan"))

    _set(LTE_RSRP, data["lte_rsrp"])
    _set(LTE_RSRQ, data["lte_rsrq"])
    _set(LTE_SNR, data["lte_snr"])
    _set(NR_RSRP, data["nr_rsrp"])
    _set(NR_RSRQ, data["nr_rsrq"])
    _set(NR_SNR, data["nr_snr"])

    lte_q = quality_score(data["lte_snr"], data["lte_rsrq"], data["lte_rsrp"])
    nr_q = quality_score(data["nr_snr"], data["nr_rsrq"], data["nr_rsrp"])
    # No signal components → quality 0 (not NaN) so dashboards show "no signal"
    LTE_QUALITY.set(lte_q if lte_q is not None else 0)
    NR_QUALITY.set(nr_q if nr_q is not None else 0)

    if data["service_type"]:
        SERVICE_TYPE.info({"type": data["service_type"]})
    if data["band"]:
        RADIO_BAND.info({"band": data["band"]})

    scrape_unixtime = time.time()
    LAST_SCRAPE_UNIXTIME.set(scrape_unixtime)
    set_source_state(source_state, source_message, empty_streak)
    scrape_success = 1 if source_state in ("ok", "no_signal") else 0
    SCRAPE_SUCCESS.set(scrape_success)
    log.info(
        "state=%s streak=%s | LTE q=%s (RSRP=%s RSRQ=%s SNR=%s) | 5G q=%s (RSRP=%s RSRQ=%s SNR=%s) | %s • %s",
        source_state,
        empty_streak,
        lte_q, data["lte_rsrp"], data["lte_rsrq"], data["lte_snr"],
        nr_q, data["nr_rsrp"], data["nr_rsrq"], data["nr_snr"],
        data["band"], data["service_type"],
    )

    return {
        "lte_quality": lte_q if lte_q is not None else 0,
        "nr_quality": nr_q if nr_q is not None else 0,
        "lte_rsrp": data["lte_rsrp"],
        "lte_rsrq": data["lte_rsrq"],
        "lte_snr": data["lte_snr"],
        "nr_rsrp": data["nr_rsrp"],
        "nr_rsrq": data["nr_rsrq"],
        "nr_snr": data["nr_snr"],
        "band": data["band"],
        "service_type": data["service_type"],
        "source_state": source_state,
        "source_message": source_message,
        "empty_streak": empty_streak,
        "heartbeat_unixtime": heartbeat_unixtime,
        "scrape_unixtime": scrape_unixtime,
        "scrape_success": scrape_success,
        "timestamp": scrape_unixtime,
    }


# --------------- Browser automation ---------------

class HotspotScraper:
    def __init__(self):
        self._pw = None
        self._browser = None
        self._page = None
        self._diag_target = f"{HOTSPOT_URL}/index.html#{DIAG_HASH}"
        self._model_events: queue.Queue = queue.Queue(maxsize=32)
        self._last_model_event = 0.0

    def start(self):
        self._pw = sync_playwright().start()
        try:
            self._browser = self._pw.chromium.launch(headless=True)
            self._page = self._browser.new_page()
            self._page.on("response", self._on_response)
            self._login()
            self._navigate_to_diagnostics(force_reload=False)
        except Exception:
            self.stop()
            raise

    def _on_response(self, response):
        if "/api/model.json" not in response.url:
            return
        try:
            model = response.json()
        except Exception:
            return

        data, state, message = parse_model_payload(model)
        event_time = time.time()
        self._last_model_event = event_time

        while self._model_events.qsize() >= 4:
            try:
                self._model_events.get_nowait()
            except queue.Empty:
                break
        try:
            self._model_events.put_nowait((data, state, message, event_time))
        except queue.Full:
            pass

    def get_latest_model_event(self, timeout: float):
        try:
            event = self._model_events.get(timeout=timeout)
        except queue.Empty:
            return None

        # Collapse burst events to the freshest sample.
        while True:
            try:
                event = self._model_events.get_nowait()
            except queue.Empty:
                break
        return event

    def _login(self):
        log.info("Logging in to %s …", HOTSPOT_URL)
        self._page.goto(HOTSPOT_URL, wait_until="networkidle", timeout=30_000)
        time.sleep(2)  # let SPA hydrate

        # Attempt form login — use Netgear-specific IDs
        try:
            pw_input = self._page.wait_for_selector(
                '#session_password', timeout=10_000
            )
            pw_input.fill(PASSWORD)

            # Click submit button
            submit = self._page.query_selector('#login_submit')
            if submit:
                submit.click()
            else:
                pw_input.press("Enter")

            self._page.wait_for_load_state("networkidle", timeout=15_000)
            time.sleep(2)
            log.info("Login completed.")
        except PwTimeout:
            log.warning("No password field found — may already be logged in.")

    def _navigate_to_diagnostics(self, force_reload: bool):
        did_nav = False
        if self._page.url != self._diag_target:
            self._page.goto(self._diag_target, wait_until="networkidle", timeout=20_000)
            did_nav = True
        elif force_reload:
            self._page.reload(wait_until="networkidle", timeout=20_000)
            did_nav = True
        if did_nav:
            time.sleep(2)  # let SPA render diagnostics

    def _is_login_page(self) -> bool:
        """Detect if we've been redirected back to login."""
        el = self._page.query_selector('#session_password')
        if not el:
            return False
        return el.is_visible()

    def scrape(self) -> str | None:
        """Fallback poll path: force reload diagnostics page and return page text."""
        try:
            self._navigate_to_diagnostics(force_reload=True)

            if self._is_login_page():
                log.info("Session expired, re-authenticating…")
                self._login()
                self._navigate_to_diagnostics(force_reload=False)

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
    _start_sse_server()

    log.info("Streaming model events (fallback poll after %ds silence) …", SCRAPE_INTERVAL)
    scraper = None
    empty_streak = 0
    restart_threshold = 5
    try:
        while True:
            heartbeat_now = time.time()
            EXPORTER_HEARTBEAT_UNIXTIME.set(heartbeat_now)
            SCRAPE_ATTEMPT_TOTAL.inc()

            if scraper is None:
                try:
                    scraper = HotspotScraper()
                    scraper.start()
                except Exception:
                    empty_streak += 1
                    SCRAPE_FAILURE_TOTAL.inc()
                    log.exception("Failed to initialize scraper")
                    payload = update_gauges(
                        empty_diagnostics(),
                        "startup_error",
                        "browser initialization failed",
                        empty_streak,
                        heartbeat_now,
                    )
                    sse_broadcaster.broadcast(payload)
                    backoff_seconds = min(SCRAPE_INTERVAL * max(1, restart_threshold // 5), 60)
                    restart_threshold = min(restart_threshold * 2, 60)
                    log.warning("Retrying startup in %ds (threshold now %d)", backoff_seconds, restart_threshold)
                    time.sleep(backoff_seconds)
                    continue

            event = scraper.get_latest_model_event(timeout=SCRAPE_INTERVAL)
            if event is not None:
                data, state, message, _event_time = event
            else:
                log.warning("No model stream update for %ds, running fallback page poll", SCRAPE_INTERVAL)
                text = scraper.scrape()
                if text is None:
                    state = "scrape_error"
                    message = "fallback scrape returned no data"
                    data = empty_diagnostics()
                else:
                    data = parse_diagnostics(text)
                    state, message = classify_source_state(text, data)

            if state in ("source_unavailable", "parse_warning", "scrape_error", "startup_error"):
                empty_streak += 1
                SCRAPE_FAILURE_TOTAL.inc()
            else:
                empty_streak = 0
                restart_threshold = 5

            payload = update_gauges(data, state, message, empty_streak, heartbeat_now)
            sse_broadcaster.broadcast(payload)

            if state in ("source_unavailable", "parse_warning", "scrape_error") and empty_streak >= restart_threshold:
                backoff_seconds = min(SCRAPE_INTERVAL * max(1, restart_threshold // 5), 60)
                log.warning(
                    "Restarting browser after %d consecutive '%s' states (backoff=%ds, next threshold=%d)",
                    empty_streak,
                    state,
                    backoff_seconds,
                    min(restart_threshold * 2, 60),
                )
                restart_threshold = min(restart_threshold * 2, 60)
                scraper.stop()
                scraper = None
                time.sleep(backoff_seconds)
                continue

    except KeyboardInterrupt:
        log.info("Shutting down…")
    finally:
        if scraper is not None:
            scraper.stop()


if __name__ == "__main__":
    run()
