import os
import time
import random
import threading
from datetime import datetime, timezone
from flask import Flask, request, jsonify
import Request, Response
# In your app, track these:
# http_requests_total{method, path, status_code}
# http_request_duration_seconds (histogram)
# app_uptime_seconds
# app_mode  (0=stable, 1=canary)
# chaos_active (0=none, 1=slow, 2=error)

# Use the prometheus_client library
from prometheus_client import Counter, Histogram, Gauge, generate_latest

REQUEST_COUNT = Counter('http_requests_total', 'Total requests', ['method', 'path', 'status_code'])
REQUEST_LATENCY = Histogram('http_request_duration_seconds', 'Latency', buckets=[.005,.01,.025,.05,.1,.25,.5,1,2.5,5,10])
UPTIME = Gauge('app_uptime_seconds', 'Uptime')
APP_MODE = Gauge('app_mode', 'Mode (0=stable 1=canary)')
CHAOS_ACTIVE = Gauge('chaos_active', 'Chaos state')


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


@app.before_request
def before_request():
    request.start_time = time.time()

@app.after_request
def after_request(response):
    if request.path == "/metrics":
        return response
    
    latency = time.time() - request.start_time
    REQUEST_LATENCY.observe(latency)
    REQUEST_COUNT.labels(
        method=request.method,
        path=request.path,
        status_code=response.status_code
    ).inc()
    return response


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

@app.get("/metrics")
def metrics():
    UPTIME.set(time.time() - START_TIME)
    APP_MODE.set(1 if get_mode() == "canary" else 0)
    
    with _chaos_lock:
        chaos = _chaos["mode"]
        if chaos == "slow":
            CHAOS_ACTIVE.set(1)
        elif chaos == "error":
            CHAOS_ACTIVE.set(2)
        else:
            CHAOS_ACTIVE.set(0)
            
    return Response(generate_latest(), media_type="text/plain")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=3000)