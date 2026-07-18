#!/usr/bin/env python3
import json
import os
import signal
import socket
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


FIXTURE_ROOT = Path.cwd() / ".fixture"
DATABASE_PATH = FIXTURE_ROOT / "state.sqlite3"
EVIDENCE_ROOT = Path(os.environ["FKST_FIXTURE_EVIDENCE_DIR"])


def inherited_listener():
    if os.environ.get("FKST_LISTEN_FDS") != "1":
        raise RuntimeError("database requires exactly one inherited listener")
    if os.environ.get("FKST_LISTEN_FDNAMES") != "database":
        raise RuntimeError("database listener name is invalid")
    return socket.socket(fileno=3)


def state_payload():
    with sqlite3.connect(DATABASE_PATH) as database:
        try:
            metadata = dict(database.execute("SELECT key, value FROM fixture_metadata"))
            row = database.execute("SELECT message FROM fixture_seed ORDER BY id LIMIT 1").fetchone()
        except sqlite3.OperationalError:
            return {"migrated": False, "seeded": False, "message": None, "row_count": 0}
        count = database.execute("SELECT COUNT(*) FROM fixture_seed").fetchone()[0]
        return {
            "migrated": metadata.get("migrated") == "true",
            "seeded": metadata.get("seeded") == "true" and count == 1,
            "message": row[0] if row else None,
            "row_count": count,
        }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def send_json(self, status, payload):
        body = (json.dumps(payload, sort_keys=True) + "\n").encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/ready":
            self.send_json(200, {"ready": True})
            return
        if self.path == "/state":
            self.send_json(200, state_payload())
            return
        self.send_json(404, {"error": "not-found"})

    def do_POST(self):
        FIXTURE_ROOT.mkdir(parents=True, exist_ok=True)
        if self.path == "/migrate":
            with sqlite3.connect(DATABASE_PATH) as database:
                database.executescript("""
                    CREATE TABLE IF NOT EXISTS fixture_metadata (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS fixture_seed (
                        id INTEGER PRIMARY KEY,
                        message TEXT NOT NULL
                    );
                    INSERT INTO fixture_metadata(key, value) VALUES ('migrated', 'true')
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """)
            self.send_response(204)
            self.end_headers()
            return
        if self.path == "/seed":
            with sqlite3.connect(DATABASE_PATH) as database:
                migrated = database.execute(
                    "SELECT value FROM fixture_metadata WHERE key = 'migrated'"
                ).fetchone()
                if migrated != ("true",):
                    self.send_json(409, {"error": "migration-required"})
                    return
                database.execute("DELETE FROM fixture_seed")
                database.execute(
                    "INSERT INTO fixture_seed(id, message) VALUES (?, ?)",
                    (1, "seeded-through-sql"),
                )
                database.execute(
                    "INSERT INTO fixture_metadata(key, value) VALUES ('seeded', 'true') "
                    "ON CONFLICT(key) DO UPDATE SET value = excluded.value"
                )
            self.send_response(204)
            self.end_headers()
            return
        self.send_json(404, {"error": "not-found"})


listener = inherited_listener()
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler, bind_and_activate=False)
server.socket.close()
server.socket = listener
server.server_address = listener.getsockname()


def shutdown(_signum, _frame):
    EVIDENCE_ROOT.mkdir(parents=True, exist_ok=True)
    (EVIDENCE_ROOT / "database-stopped.json").write_text(
        json.dumps({"role": "database", "sqlite_path": str(DATABASE_PATH)}) + "\n",
        encoding="utf-8",
    )
    threading.Thread(target=server.shutdown, daemon=True).start()


signal.signal(signal.SIGTERM, shutdown)
server.serve_forever()
server.server_close()
