#!/usr/bin/env python3
"""Private, dependency-free reporting for official SendFile downloads.

Raw client addresses exist only in Nginx's short-lived access log.  This
script replaces that file before processing it, stores only HMAC-SHA-256
digests in SQLite, and never prints an address in a report.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import hmac
import json
import os
import sqlite3
import subprocess
import sys
import time
from datetime import date, timedelta
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
LOG_DIR = ROOT / "logs"
LOG_FILE = LOG_DIR / "downloads.json"
DATABASE = DATA_DIR / "download-stats.sqlite3"
KEY_FILE = DATA_DIR / "download-stats.key"
LOCK_FILE = DATA_DIR / ".download-stats.lock"
RETENTION_DAYS = 90


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Report private SendFile download statistics.")
    parser.add_argument("--ingest", action="store_true", help="Process new access-log entries and exit.")
    parser.add_argument("--days", type=int, default=30, help="Report period, from 1 to 90 days (default: 30).")
    parser.add_argument("--container", default="sendfile-web", help="Nginx container name.")
    return parser.parse_args()


def private_key() -> bytes:
    DATA_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        return KEY_FILE.read_bytes()
    except FileNotFoundError:
        key = os.urandom(32)
        fd = os.open(KEY_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(key)
        return key


def database() -> sqlite3.Connection:
    DATA_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    connection = sqlite3.connect(DATABASE)
    connection.executescript(
        """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS daily_stats (
          day TEXT NOT NULL,
          file_name TEXT NOT NULL,
          requests INTEGER NOT NULL DEFAULT 0,
          full_responses INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (day, file_name)
        );
        CREATE TABLE IF NOT EXISTS daily_unique (
          day TEXT NOT NULL,
          file_name TEXT NOT NULL,
          address_hash BLOB NOT NULL,
          PRIMARY KEY (day, file_name, address_hash)
        );
        """
    )
    return connection


def rotate_log(container: str) -> Path | None:
    """Atomically hand Nginx a new log then return the closed old log."""
    LOG_DIR.mkdir(mode=0o755, parents=True, exist_ok=True)
    if not LOG_FILE.exists() or LOG_FILE.stat().st_size == 0:
        return None
    rotated = LOG_DIR / f"downloads.{int(time.time() * 1000)}.processing"
    os.replace(LOG_FILE, rotated)
    LOG_FILE.touch(mode=0o640)
    try:
        subprocess.run(["docker", "kill", "--signal=USR1", container], check=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError) as error:
        # Preserve the log rather than risk losing entries when the container is unavailable.
        os.replace(rotated, LOG_FILE)
        raise RuntimeError(f"Cannot reopen Nginx access log: {error}") from error
    time.sleep(0.2)
    return rotated


def client_digest(value: str, key: bytes) -> bytes | None:
    address = value.split(",", 1)[0].strip()
    if not address:
        return None
    return hmac.new(key, address.encode("utf-8"), hashlib.sha256).digest()


def ingest(rotated: Path | None, connection: sqlite3.Connection, key: bytes) -> int:
    if rotated is None:
        return 0
    processed = 0
    try:
        with rotated.open("r", encoding="utf-8") as lines:
            for line in lines:
                try:
                    item = json.loads(line)
                    uri = item.get("uri", "")
                    status = int(item.get("status", 0))
                except (ValueError, TypeError, json.JSONDecodeError):
                    continue
                if item.get("method") != "GET" or not uri.startswith("/downloads/") or status not in (200, 206):
                    continue
                file_name = Path(uri).name
                if not file_name or file_name != uri.removeprefix("/downloads/"):
                    continue
                day = str(item.get("time", ""))[:10]
                if len(day) != 10:
                    continue
                expected = ROOT / "public" / "downloads" / file_name
                try:
                    sent = int(item.get("body_bytes_sent", 0))
                    full = int(status == 200 and not item.get("range") and expected.is_file() and sent >= expected.stat().st_size)
                except (ValueError, OSError):
                    full = 0
                connection.execute(
                    """INSERT INTO daily_stats(day, file_name, requests, full_responses) VALUES (?, ?, 1, ?)
                       ON CONFLICT(day, file_name) DO UPDATE SET requests = requests + 1,
                       full_responses = full_responses + excluded.full_responses""",
                    (day, file_name, full),
                )
                digest = client_digest(str(item.get("forwarded_for", "")), key)
                if digest:
                    connection.execute(
                        "INSERT OR IGNORE INTO daily_unique(day, file_name, address_hash) VALUES (?, ?, ?)",
                        (day, file_name, digest),
                    )
                processed += 1
        cutoff = (date.today() - timedelta(days=RETENTION_DAYS)).isoformat()
        connection.execute("DELETE FROM daily_unique WHERE day < ?", (cutoff,))
        connection.commit()
    finally:
        rotated.unlink(missing_ok=True)
    return processed


def report(connection: sqlite3.Connection, days: int) -> None:
    if not 1 <= days <= RETENTION_DAYS:
        raise ValueError(f"--days must be between 1 and {RETENTION_DAYS}")
    start = (date.today() - timedelta(days=days - 1)).isoformat()
    rows = connection.execute(
        """SELECT stats.file_name, SUM(stats.requests), SUM(stats.full_responses),
                  (SELECT COUNT(DISTINCT address_hash) FROM daily_unique unique_rows
                   WHERE unique_rows.file_name = stats.file_name AND unique_rows.day >= ?)
           FROM daily_stats stats WHERE stats.day >= ? GROUP BY stats.file_name ORDER BY stats.file_name""",
        (start, start),
    ).fetchall()
    print(f"SendFile over WiFi — private download report, last {days} day(s)")
    print("Geolocation: disabled (no IP data is sent to third parties).")
    if not rows:
        print("No download requests recorded yet.")
        return
    headers = ("File", "HTTP requests", "Full responses", "Unique visitors")
    values = [(str(row[0]), str(row[1]), str(row[2]), str(row[3])) for row in rows]
    widths = [max(len(headers[index]), *(len(row[index]) for row in values)) for index in range(4)]
    print("  ".join(headers[index].ljust(widths[index]) for index in range(4)))
    print("  ".join("-" * width for width in widths))
    for row in values:
        print("  ".join(row[index].ljust(widths[index]) for index in range(4)))
    print("Full response means the server sent the complete non-range file; it does not confirm installation.")


def main() -> int:
    args = parse_args()
    DATA_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    with LOCK_FILE.open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        key = private_key()
        connection = database()
        try:
            processed = ingest(rotate_log(args.container), connection, key)
            if args.ingest:
                print(f"Processed {processed} download request(s).")
            else:
                report(connection, args.days)
        finally:
            connection.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError) as error:
        print(f"download-report: {error}", file=sys.stderr)
        raise SystemExit(1)
