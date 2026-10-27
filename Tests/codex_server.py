"""Local protocol fixture. Makes no network requests."""
import json
import sys
import threading
import time

lock = threading.Lock()
reads = 0


def emit(message):
    with lock:
        print(json.dumps(message), flush=True)


def bucket(used):
    return {"limitId": "codex", "primary": {"usedPercent": used, "windowDurationMins": 10080}}


for line in sys.stdin:
    message = json.loads(line)
    if message["method"] == "initialize":
        emit({"id": message["id"], "result": {}})
    elif message["method"] == "account/rateLimits/read":
        if "--hang" in sys.argv:
            time.sleep(10)
            continue
        reads += 1
        if reads == 3:
            sys.exit(0)
        emit({"id": message["id"], "result": {
            "rateLimits": bucket(25 if reads == 1 else 30),
            "rateLimitResetCredits": {"availableCount": 2},
        }})
        if reads == 2:
            threading.Timer(0.1, lambda: emit({"method": "account/rateLimits/updated", "params": {"rateLimits": bucket(75)}})).start()
