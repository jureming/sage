#!/usr/bin/env python3
import fnmatch
import json
import os
import socket
import subprocess
import time

import salt.config
import salt.utils.event


MASTER_CONFIG = "/etc/salt/master"
EVENT_TAG_PATTERN = "salt/framework/async/*"
SLACK_NOTIFY_WRAPPER = "/data/salt/common/framework_async_slack_notify.sh"
DEDUP_FILE = "/var/tmp/salt_framework_slack_event_dedup.json"
LOG_FILE = "/var/log/salt/framework_slack_event_listener.log"


def log(message):
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"{now} {message}\n"

    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass

    print(line, end="", flush=True)


def load_dedup():
    try:
        with open(DEDUP_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return {}

    if not isinstance(data, dict):
        return {}

    now = int(time.time())
    cleaned = {}

    for key, ts in data.items():
        try:
            ts_int = int(ts)
        except Exception:
            continue

        if now - ts_int < 86400:
            cleaned[key] = ts_int

    return cleaned


def save_dedup(data):
    try:
        with open(DEDUP_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, sort_keys=True)
    except Exception as e:
        log(f"dedup_save_error error={e}")


def normalize_event_payload(raw_data):
    if not isinstance(raw_data, dict):
        return {}

    inner = raw_data.get("data")
    if isinstance(inner, dict):
        payload = dict(inner)
    else:
        payload = dict(raw_data)

    if "minion_id" not in payload:
        if isinstance(raw_data.get("id"), str):
            payload["minion_id"] = raw_data["id"]

    return payload


def make_fallback_title(payload):
    status = str(payload.get("status", "unknown"))
    task_name = str(payload.get("task_name", "unknown"))
    minion_id = str(payload.get("minion_id", "unknown"))

    if status == "success":
        return f"Salt ASYNC �묒뾽 �꾨즺 - {task_name} / {minion_id}"

    return f"Salt ASYNC �묒뾽 �ㅽ뙣 - {task_name} / {minion_id}"


def make_fallback_payload(tag, payload):
    run_id = str(payload.get("run_id", "unknown"))
    task_name = str(payload.get("task_name", "unknown"))
    minion_id = str(payload.get("minion_id", "unknown"))
    status = str(payload.get("status", "unknown"))
    exit_code = str(payload.get("exit_code", "unknown"))
    started_at = str(payload.get("started_at", "unknown"))
    ended_at = str(payload.get("ended_at", "unknown"))
    duration_sec = str(payload.get("duration_sec", "unknown"))
    base_dir = str(payload.get("base_dir", "unknown"))

    lines = [
        f"status: {status}",
        f"minion: {minion_id}",
        f"task: {task_name}",
        f"run_id: {run_id}",
        f"exit_code: {exit_code}",
        f"started_at: {started_at}",
        f"ended_at: {ended_at}",
        f"duration_sec: {duration_sec}",
        f"base_dir: {base_dir}",
        f"event_tag: {tag}",
    ]

    return "\n".join(lines)



def get_local_master_ips():
    ips = []

    for _ in range(3):
        try:
            proc = subprocess.run(
                ["hostname", "-I"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=3,
            )
        except Exception:
            time.sleep(1)
            continue

        if proc.returncode != 0:
            time.sleep(1)
            continue

        for item in proc.stdout.strip().split():
            item = item.strip()

            if item and item not in ips:
                ips.append(item)

        if ips:
            break

        time.sleep(1)

    return ips

def send_slack(slack_target, title, payload):
    if not os.path.exists(SLACK_NOTIFY_WRAPPER):
        return False, f"wrapper_not_found path={SLACK_NOTIFY_WRAPPER}"

    try:
        proc = subprocess.run(
            [SLACK_NOTIFY_WRAPPER, slack_target, title, payload],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        return False, "wrapper_timeout"
    except Exception as e:
        return False, f"wrapper_exec_error error={e}"

    stdout = proc.stdout.strip().replace("\n", "\\n")
    stderr = proc.stderr.strip().replace("\n", "\\n")

    if proc.returncode == 0:
        return True, f"rc=0 stdout={stdout}"

    return False, f"rc={proc.returncode} stdout={stdout} stderr={stderr}"


def main():
    opts = salt.config.client_config(MASTER_CONFIG)
    sock_dir = opts.get("sock_dir", "/var/run/salt/master")

    event = salt.utils.event.get_event(
        "master",
        sock_dir=sock_dir,
        opts=opts,
        listen=True,
    )

    hostname = socket.gethostname()
    local_master_ips = get_local_master_ips()
    dedup = load_dedup()

    log(
        f"listener_start host={hostname} "
        f"pattern={EVENT_TAG_PATTERN} "
        f"sock_dir={sock_dir} "
        f"local_master_ips={','.join(local_master_ips)}"
    )

    while True:
        try:
            ret = event.get_event(wait=5, full=True)
        except Exception as e:
            log(f"event_read_error error={e}")
            time.sleep(5)
            continue

        if ret is None:
            continue

        tag = ret.get("tag", "")
        raw_data = ret.get("data", {})

        if not fnmatch.fnmatch(tag, EVENT_TAG_PATTERN):
            continue

        payload = normalize_event_payload(raw_data)

        run_id = str(payload.get("run_id", "unknown"))
        minion_id = str(payload.get("minion_id", raw_data.get("id", "unknown")))
        status = str(payload.get("status", "unknown"))
        ended_at = str(payload.get("ended_at", "unknown"))
        slack_target = str(payload.get("slack_target", "")).strip()
        event_master = str(payload.get("event_master", "")).strip()

        if event_master and local_master_ips and event_master not in local_master_ips:
            log(
                f"event_skip reason=event_master_mismatch "
                f"event_master={event_master} "
                f"local_master_ips={','.join(local_master_ips)} "
                f"tag={tag} run_id={run_id} minion={minion_id}"
            )
            continue

        if not slack_target:
            log(f"slack_skip reason=no_slack_target tag={tag} run_id={run_id} minion={minion_id}")
            continue

        title = str(payload.get("slack_title") or make_fallback_title(payload))
        message = str(payload.get("slack_content") or make_fallback_payload(tag, payload))

        dedup_key = f"{tag}|{run_id}|{minion_id}|{status}|{ended_at}|{slack_target}"

        if dedup_key in dedup:
            log(f"duplicate_skip target={slack_target} key={dedup_key}")
            continue

        ok, detail = send_slack(slack_target, title, message)

        if ok:
            dedup[dedup_key] = int(time.time())
            save_dedup(dedup)
            log(f"slack_sent target={slack_target} key={dedup_key} {detail}")
        else:
            log(f"slack_send_failed target={slack_target} key={dedup_key} {detail}")


if __name__ == "__main__":
    main()
