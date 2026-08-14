# ==============================================================================
# Dockerfile — Containerized Flask app for the homelab
#
# Uses python:3.11-slim as the base (Debian Bookworm minimal — ~120MB).
# Full python:3.11 adds ~600MB of build tools we don't need at runtime.
#
# Build context: the app/ directory (set via docker-compose.yml `build: ../app`)
# ==============================================================================

FROM python:3.11-slim

WORKDIR /app

# Install dependencies first (before copying app code) so Docker can cache
# this layer. Requirements only change when we add/upgrade packages.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Now copy the application code — this layer busts cache on every code change
COPY server.py .

# Document the port the app listens on (informational — actual mapping is in docker-compose)
EXPOSE 5000

# --- Production server ---
# gunicorn replaces Flask's built-in dev server:
#   - 2 workers: enough for a homelab with <10 concurrent users. Formula is
#     typically (2 * CPU cores + 1), but on t2.micro with 1 core, 2 is fine.
#   - --access-logfile -: prints access logs to stdout → captured by Docker → shipped to CloudWatch
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--access-logfile", "-", "server:app"]
