"""Load the dashboard in a headless browser and verify it renders correctly.

Checks:
  1. Page loads without JS console errors
  2. All expected canvas elements exist
  3. Canvases have non-zero dimensions (drawn, not collapsed)
  4. Key DOM elements (gauges, status bar values) are present

Usage:  python scripts/validate-dashboard.py [URL]
        Default URL: http://localhost:8080
"""

import sys
import time

DASHBOARD_URL = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"
WAIT_SECONDS = 4  # let the page settle and attempt initial draws

EXPECTED_CANVASES = ["chart", "lte-raw-chart", "nr-raw-chart"]

EXPECTED_ELEMENTS = [
    "#lte-q", "#nr-q",          # quality boxes
    "#band", "#svc",            # status bar
    "#lte-rsrp", "#nr-rsrp",    # gauge values
]

errors = []
warnings = []
console_errors = []


def ok(msg):
    print(f"  \033[32m[ok]\033[0m {msg}")


def warn(msg):
    warnings.append(msg)
    print(f"  \033[33m[warn]\033[0m {msg}")


def fail(msg):
    errors.append(msg)
    print(f"  \033[31m[FAIL]\033[0m {msg}")


def run():
    from playwright.sync_api import sync_playwright

    print(f"Validating dashboard at {DASHBOARD_URL} ...")

    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True)
        page = browser.new_page()

        page.on("console", lambda msg: (
            console_errors.append(msg.text)
            if msg.type in ("error",) else None
        ))

        try:
            page.goto(DASHBOARD_URL, wait_until="domcontentloaded", timeout=10_000)
        except Exception as e:
            fail(f"Page failed to load: {e}")
            browser.close()
            return False

        ok("Page loaded")

        # Give charts time to draw
        time.sleep(WAIT_SECONDS)

        # Check console errors
        if console_errors:
            for ce in console_errors:
                fail(f"JS console error: {ce}")
        else:
            ok("No JS console errors")

        # Check canvases exist and have been sized
        for canvas_id in EXPECTED_CANVASES:
            el = page.query_selector(f"#{canvas_id}")
            if not el:
                fail(f"Canvas #{canvas_id} not found in DOM")
                continue
            dims = page.evaluate(
                """(id) => {
                    var c = document.getElementById(id);
                    return { w: c.width, h: c.height };
                }""",
                canvas_id,
            )
            if dims["w"] > 0 and dims["h"] > 0:
                ok(f"Canvas #{canvas_id} rendered ({dims['w']}x{dims['h']})")
            else:
                fail(f"Canvas #{canvas_id} has zero dimensions ({dims['w']}x{dims['h']})")

        # Check canvases have actual drawn content (not blank)
        for canvas_id in EXPECTED_CANVASES:
            has_content = page.evaluate(
                """(id) => {
                    var c = document.getElementById(id);
                    if (!c || c.width === 0 || c.height === 0) return false;
                    var ctx = c.getContext('2d');
                    // Sample a few rows of pixels to see if anything was drawn
                    var data = ctx.getImageData(0, 0, c.width, c.height).data;
                    for (var i = 3; i < data.length; i += 4) {
                        if (data[i] > 0) return true;
                    }
                    return false;
                }""",
                canvas_id,
            )
            if has_content:
                ok(f"Canvas #{canvas_id} has drawn content")
            else:
                fail(f"Canvas #{canvas_id} is blank (no pixels drawn)")

        # Check key DOM elements
        for selector in EXPECTED_ELEMENTS:
            el = page.query_selector(selector)
            if el:
                ok(f"Element {selector} present")
            else:
                fail(f"Element {selector} missing")

        browser.close()

    return len(errors) == 0


if __name__ == "__main__":
    print()
    success = run()
    print()
    if errors:
        print(f"\033[31m{len(errors)} error(s), {len(warnings)} warning(s)\033[0m")
        sys.exit(1)
    elif warnings:
        print(f"\033[33m0 errors, {len(warnings)} warning(s)\033[0m")
    else:
        print("\033[32mAll checks passed.\033[0m")
