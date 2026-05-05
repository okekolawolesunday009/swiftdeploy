import os
import time
import random
import threading
from datetime import datetime, timezone
from flask import Flask, request, jsonify

app = Flask(__name__)

START_TIME = time.time()

# Chaos state
_chaos_lock = threading.Lock()
_chaos = {
    "mode": None,       # None | "slow" | "error"
    "duration": 0,      # seconds to sleep (slow mode)
    "rate": 0.0,        # error probability (error mode)
}


def get_mode():
    return os.environ.get("MODE", "stable")


def get_version():
    return os.environ.get("VERSION", "1.0.0")


def apply_chaos():
    """Apply any active chaos effects. Returns (should_error, sleep_seconds)."""
    with _chaos_lock:
        mode = _chaos["mode"]
        if mode == "slow":
            return False, _chaos["duration"]
        elif mode == "error":
            if random.random() < _chaos["rate"]:
                return True, 0
    return False, 0


@app.route("/")
def index():
    should_error, sleep_secs = apply_chaos()
    if sleep_secs:
        time.sleep(sleep_secs)
    if should_error:
        return jsonify({"error": "Internal Server Error (chaos)", "code": 500}), 500

    return jsonify({
        "message": "SwiftDeploy service is running",
        "mode": get_mode(),
        "version": get_version(),
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })


@app.route("/healthz")
def healthz():
    uptime = int(time.time() - START_TIME)
    return jsonify({
        "status": "ok",
        "uptime_seconds": uptime,
    })


@app.route("/chaos", methods=["POST"])
def chaos():
    if get_mode() != "canary":
        return jsonify({"error": "Forbidden — /chaos is only available in canary mode"}), 403

    data = request.get_json(force=True, silent=True) or {}
    chaos_mode = data.get("mode")

    if chaos_mode == "recover":
        with _chaos_lock:
            _chaos["mode"] = None
            _chaos["duration"] = 0
            _chaos["rate"] = 0.0
        return jsonify({"status": "recovered", "chaos": "none"})

    elif chaos_mode == "slow":
        duration = float(data.get("duration", 5))
        with _chaos_lock:
            _chaos["mode"] = "slow"
            _chaos["duration"] = duration
            _chaos["rate"] = 0.0
        return jsonify({"status": "chaos active", "mode": "slow", "duration": duration})

    elif chaos_mode == "error":
        rate = float(data.get("rate", 0.5))
        rate = max(0.0, min(1.0, rate))
        with _chaos_lock:
            _chaos["mode"] = "error"
            _chaos["duration"] = 0
            _chaos["rate"] = rate
        return jsonify({"status": "chaos active", "mode": "error", "rate": rate})

    else:
        return jsonify({"error": "Invalid chaos mode. Use: slow | error | recover"}), 400


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=3000)