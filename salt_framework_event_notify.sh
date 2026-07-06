#!/usr/bin/env bash
# ============================================================
# Salt Framework Async Result Event Library
# ============================================================
# 이 파일은 ASYNC_RESULT=true 인 RUN_SCRIPT 작업에서 salt_apply가
# minion payload 안에 자동으로 포함해 사용하는 공통 event 전송 함수다.
#
# remote 사용자는 이 파일을 직접 source 하지 않는다.
# remote 안에서는 async_done_send_files 를 직접 호출하지 않는다.
# ============================================================

: "${FRAMEWORK_EVENT_TAG:=salt/framework/async/done}"
: "${FRAMEWORK_RUN_ID:=manual_$(date '+%Y%m%d%H%M%S')_$$}"
: "${FRAMEWORK_TASK_NAME:=unknown_task}"
: "${FRAMEWORK_BASE_DIR:=unknown_base_dir}"

if [[ -z "${FRAMEWORK_STARTED_AT:-}" ]]; then
    FRAMEWORK_STARTED_AT="$(date '+%F %T')"
fi

if [[ -z "${FRAMEWORK_STARTED_EPOCH:-}" ]]; then
    FRAMEWORK_STARTED_EPOCH="$(date +%s)"
fi

_salt_framework_get_salt_call_bin() {
    local bin=""

    if [[ -n "${SALT_CALL_BIN:-}" && -x "${SALT_CALL_BIN:-}" ]]; then
        printf '%s\n' "$SALT_CALL_BIN"
        return 0
    fi

    if [[ -x /usr/local/bin/salt-call ]]; then
        printf '%s\n' "/usr/local/bin/salt-call"
        return 0
    fi

    if [[ -x /opt/saltstack/salt/bin/salt-call ]]; then
        printf '%s\n' "/opt/saltstack/salt/bin/salt-call"
        return 0
    fi

    if [[ -x /opt/salt/bin/salt-call ]]; then
        printf '%s\n' "/opt/salt/bin/salt-call"
        return 0
    fi

    bin="$(command -v salt-call 2>/dev/null || true)"

    if [[ -n "$bin" && -x "$bin" ]]; then
        printf '%s\n' "$bin"
        return 0
    fi

    printf '%s\n' "salt-call"
    return 0
}

get_salt_minion_id() {
    local minion_id=""
    local salt_call_bin=""

    salt_call_bin="$(_salt_framework_get_salt_call_bin)"

    minion_id="$(
        "$salt_call_bin" --local config.get id --out=txt 2>/dev/null \
            | awk -F': ' '{print $2}' \
            | tail -1
    )"

    if [[ -z "$minion_id" ]]; then
        minion_id="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown_minion)"
    fi

    printf '%s\n' "$minion_id"
}

async_done_send_files() {
    local exit_code="${1:-0}"
    local stdout_file="${2:-}"
    local stderr_file="${3:-}"
    local status="success"
    local ended_at=""
    local now_epoch=""
    local duration_sec=0
    local minion_id=""
    local tag="${FRAMEWORK_EVENT_TAG:-salt/framework/async/done}"
    local salt_call_bin=""

    if [[ ! "$exit_code" =~ ^-?[0-9]+$ ]]; then
        exit_code=1
    fi

    if [[ "$exit_code" -ne 0 ]]; then
        status="failed"
    fi

    if [[ -z "$stdout_file" || ! -f "$stdout_file" ]]; then
        echo "async_done_send_files 오류: stdout 파일 없음: $stdout_file" >&2
        return 1
    fi

    if [[ -z "$stderr_file" || ! -f "$stderr_file" ]]; then
        echo "async_done_send_files 오류: stderr 파일 없음: $stderr_file" >&2
        return 1
    fi

    ended_at="$(date '+%F %T')"
    now_epoch="$(date +%s)"

    if [[ -n "${FRAMEWORK_STARTED_EPOCH:-}" && "$FRAMEWORK_STARTED_EPOCH" =~ ^[0-9]+$ ]]; then
        duration_sec=$(( now_epoch - FRAMEWORK_STARTED_EPOCH ))
    else
        duration_sec=0
    fi

    minion_id="$(get_salt_minion_id)"
    salt_call_bin="$(_salt_framework_get_salt_call_bin)"

    python3 - \
        "$salt_call_bin" \
        "$tag" \
        "$FRAMEWORK_RUN_ID" \
        "$FRAMEWORK_TASK_NAME" \
        "$FRAMEWORK_BASE_DIR" \
        "$minion_id" \
        "$status" \
        "$exit_code" \
        "$FRAMEWORK_STARTED_AT" \
        "$ended_at" \
        "$duration_sec" \
        "$stdout_file" \
        "$stderr_file" <<'PYASYNC'
import json
import os
import socket
import subprocess
import sys
import time

salt_call_bin = sys.argv[1]
tag = sys.argv[2]
run_id = sys.argv[3]
task_name = sys.argv[4]
base_dir = sys.argv[5]
minion_id = sys.argv[6]
status = sys.argv[7]
exit_code_raw = sys.argv[8]
started_at = sys.argv[9]
ended_at = sys.argv[10]
duration_sec_raw = sys.argv[11]
stdout_file = sys.argv[12]
stderr_file = sys.argv[13]

try:
    exit_code = int(exit_code_raw)
except Exception:
    exit_code = 1

try:
    duration_sec = int(duration_sec_raw)
except Exception:
    duration_sec = 0


def read_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except Exception:
        return ""


stdout_content = read_file(stdout_file)
stderr_content = read_file(stderr_file)

data = {
    "event_type": "async_done",
    "run_id": run_id,
    "task_name": task_name,
    "base_dir": base_dir,
    "minion_id": minion_id,
    "status": status,
    "exit_code": exit_code,
    "started_at": started_at,
    "ended_at": ended_at,
    "duration_sec": duration_sec,
    "stdout_content": stdout_content,
    "stderr_content": stderr_content,
}

exec_master = os.environ.get("FRAMEWORK_EXEC_MASTER", "").strip()
exec_master_ips_raw = os.environ.get("FRAMEWORK_EXEC_MASTER_IPS", "").strip()

if not exec_master_ips_raw:
    exec_master_ips_raw = os.environ.get("FRAMEWORK_EXEC_MASTER_IP", "").strip()


def append_unique(items, value):
    value = str(value).strip()
    if value and value not in items:
        items.append(value)


def flatten_master_values(value):
    result = []

    if value is None:
        return result

    if isinstance(value, str):
        for item in value.replace(",", " ").split():
            append_unique(result, item)
        return result

    if isinstance(value, (list, tuple, set)):
        for item in value:
            for flattened in flatten_master_values(item):
                append_unique(result, flattened)
        return result

    if isinstance(value, dict):
        if "local" in value:
            return flatten_master_values(value.get("local"))

        for item in value.values():
            for flattened in flatten_master_values(item):
                append_unique(result, flattened)
        return result

    append_unique(result, value)
    return result


def resolve_master_to_ips(master_value):
    ips = []
    master_value = str(master_value).strip()

    if not master_value:
        return ips

    try:
        infos = socket.getaddrinfo(master_value, None, socket.AF_INET, socket.SOCK_STREAM)
        for info in infos:
            append_unique(ips, info[4][0])
    except Exception:
        append_unique(ips, master_value)

    return ips


def get_minion_master_values():
    try:
        proc = subprocess.run(
            [salt_call_bin, "--local", "config.get", "master", "--out=json"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=15,
        )

        if proc.returncode == 0 and proc.stdout.strip():
            payload = json.loads(proc.stdout)
            return flatten_master_values(payload)
    except Exception:
        pass

    try:
        proc = subprocess.run(
            [salt_call_bin, "--local", "config.get", "master", "--out=txt"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=15,
        )

        if proc.returncode == 0 and proc.stdout.strip():
            values = []
            for line in proc.stdout.splitlines():
                if ":" in line:
                    line = line.split(":", 1)[1]
                for item in line.replace(",", " ").split():
                    append_unique(values, item)
            return values
    except Exception:
        pass

    return []


exec_master_ips = []
for item in exec_master_ips_raw.replace(",", " ").split():
    append_unique(exec_master_ips, item)

minion_master_values = get_minion_master_values()
minion_master_ips = []
for master_value in minion_master_values:
    for resolved_ip in resolve_master_to_ips(master_value):
        append_unique(minion_master_ips, resolved_ip)

matched_exec_master_ip = ""
for exec_master_ip in exec_master_ips:
    if exec_master_ip in minion_master_ips:
        matched_exec_master_ip = exec_master_ip
        break

data["exec_master"] = exec_master
data["exec_master_ips"] = " ".join(exec_master_ips)
data["minion_master"] = " ".join(minion_master_values)
data["minion_master_ips"] = " ".join(minion_master_ips)
data["event_master"] = matched_exec_master_ip


def fire_event_with_salt_call():
    payload = json.dumps(data, ensure_ascii=False)
    cmd = [salt_call_bin]
    if matched_exec_master_ip:
        cmd.append(f"--master={matched_exec_master_ip}")
    cmd.extend(["event.send", tag, payload, "--out=quiet"])

    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        timeout=60,
    )

    if proc.returncode != 0:
        print(
            "event.send failed "
            f"rc={proc.returncode} "
            f"salt_call_bin={salt_call_bin} "
            f"matched_exec_master_ip={matched_exec_master_ip} "
            f"exec_master={exec_master} "
            f"exec_master_ips={' '.join(exec_master_ips)} "
            f"minion_master={' '.join(minion_master_values)} "
            f"minion_master_ips={' '.join(minion_master_ips)} "
            f"stdout={proc.stdout.strip()} "
            f"stderr={proc.stderr.strip()}",
            file=sys.stderr,
        )

    return proc.returncode == 0

for attempt in range(1, 6):
    try:
        if fire_event_with_salt_call():
            sys.exit(0)
    except Exception as e:
        print(
            f"fire_event_with_salt_call failed "
            f"attempt={attempt} "
            f"error={type(e).__name__}: {e}",
            file=sys.stderr,
        )

    time.sleep(10)

print("async_done_event_send_failed_after_retries", file=sys.stderr)
sys.exit(0)
PYASYNC
}


