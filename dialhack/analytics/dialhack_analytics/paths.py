from pathlib import Path

ANALYTICS_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = ANALYTICS_DIR / "data"

#: Real telemetry from both platforms.
DB_PATH = DATA_DIR / "telemetry.duckdb"
#: Synthetic demo data (`python -m dialhack_analytics make-demo`), never mixed with real data.
DEMO_DB_PATH = DATA_DIR / "demo.duckdb"
#: Shared with the DialHack app (it can't read ~/Documents), so these live in Application Support.
APP_SUPPORT = Path.home() / "Library/Application Support/DialHack"
#: Window labels you set by hand (in the app or the dashboard).
LABELS_PATH = APP_SUPPORT / "dashboard_labels.csv"
DEMO_LABELS_PATH = DATA_DIR / "demo-labels.csv"

#: Session ids to drop at ingest (scripted tests, not real use). One id per line, '#' comments allowed.
EXCLUDE_PATH = APP_SUPPORT / "exclude_sessions.txt"

#: Where the macOS app writes events. Android exports (JSONL) are passed explicitly or dropped in DATA_DIR/inbox.
MAC_EVENTS = APP_SUPPORT / "events.jsonl"
#: Focus Timer self-report labels written by the macOS app.
MAC_LABELS = APP_SUPPORT / "labels.jsonl"
INBOX_DIR = DATA_DIR / "inbox"


def labels_path_for(db_path: Path) -> Path:
    return DEMO_LABELS_PATH if Path(db_path).resolve() == DEMO_DB_PATH.resolve() else LABELS_PATH
