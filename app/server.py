"""
server.py — Homelab Flask API

A lightweight personal API running in Docker on EC2. Provides:
  - Health check endpoint (consumed by cron-based monitoring + Docker healthcheck)
  - Service info endpoint (quick sanity check that the right version is deployed)
  - Notes CRUD (in-memory store — intentionally ephemeral for a homelab)

Not meant to be production-grade. No auth, no persistence, no HTTPS termination.
The app binds to 0.0.0.0 inside the container but Docker only exposes it on
127.0.0.1:5000 (see docker-compose.yml), so it's not reachable from the internet.

Run locally for development:
    python server.py

In production (via Docker):
    gunicorn --bind 0.0.0.0:5000 --workers 2 server:app
"""

import os
import logging
from datetime import datetime, timezone

from flask import Flask, jsonify, request

app = Flask(__name__)

# --- Logging ---
# Format logs for easy reading in CloudWatch Logs and `docker logs`.
# Using stdout (not a file) because Docker's json-file driver captures it
# and the CloudWatch Agent ships container logs from there.
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

# --- In-memory data store ---
# Resets on container restart. This is fine — it's a homelab scratchpad,
# not a production database. If persistence is needed later, swap this
# for a SQLite file or a Redis container in docker-compose.
notes = []


@app.route("/health")
def health():
    """Health check endpoint.

    Returns 200 with a timestamp. Consumed by:
      - Docker HEALTHCHECK (marks container as healthy/unhealthy)
      - cron-based health_check.sh (logs uptime to CSV)
      - Any external uptime monitor you point at it
    """
    return jsonify({"status": "healthy", "timestamp": datetime.now(timezone.utc).isoformat()})


@app.route("/")
def index():
    """Service discovery endpoint — confirms the app is running and shows available routes."""
    return jsonify({
        "service": "homelab-api",
        "version": "1.0.0",
        "uptime_check": "/health",
        "notes_endpoint": "/notes",
    })


@app.route("/notes", methods=["GET"])
def get_notes():
    """List all notes. Returns the full collection — no pagination needed at homelab scale."""
    return jsonify({"count": len(notes), "notes": notes})


@app.route("/notes", methods=["POST"])
def add_note():
    """Add a note. Expects JSON body: {"text": "your note here"}.

    IDs are sequential integers starting at 1. They're not globally unique
    and will reset on restart — again, homelab-grade, not production-grade.
    """
    data = request.get_json(silent=True)
    if not data or "text" not in data:
        return jsonify({"error": "Missing 'text' field"}), 400

    note = {
        "id": len(notes) + 1,
        "text": data["text"],
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    notes.append(note)
    logger.info("Note added: id=%d", note["id"])
    return jsonify(note), 201


@app.route("/notes/<int:note_id>", methods=["DELETE"])
def delete_note(note_id):
    """Delete a note by ID. Linear scan is fine — we'll never have thousands of notes."""
    for i, note in enumerate(notes):
        if note["id"] == note_id:
            notes.pop(i)
            logger.info("Note deleted: id=%d", note_id)
            return jsonify({"deleted": note_id}), 200
    return jsonify({"error": "Not found"}), 404


if __name__ == "__main__":
    # Local development only — in Docker, gunicorn handles startup (see Dockerfile CMD)
    port = int(os.environ.get("PORT", 5000))
    logger.info("Starting homelab server on port %d", port)
    app.run(host="0.0.0.0", port=port)
