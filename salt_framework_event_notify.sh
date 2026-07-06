# ============================================================
# Salt Framework Async Slack Event Compatibility Library
# ============================================================
# 이 파일은 salt_apply가 RUN_SCRIPT 앞에 자동으로 붙여서
# minion에서 실행되도록 사용하는 공통 함수 파일이다.
#
# async remote 사용자는 기존 post 방식과 비슷하게 아래처럼 쓴다.
#
#   webhook=$slack4
#   title="작업 제목"
#   content="작업 내용"
#   message_send "$webhook" "$title" "$content"
#
# 주의:
#   async remote 안에서는 아래 줄을 쓰지 않는다.
#
#   . /data/salt/common/send_to_slack
#
# 이유:
#   remote는 minion에서 실행된다.
#   minion은 Slack webhook을 직접 호출하지 않는다.
#   여기의 message_send 함수는 Slack curl을 실행하지 않고,
#   salt-call event.send 로 master event bus에 알림 데이터를 전달한다.
#
# master에서는 salt-framework-slack-event.service 가 이벤트를 받아
# /data/salt/common/send_to_slack 의 실제 message_send 로 Slack을 보낸다.
# ============================================================

# ------------------------------------------------------------
# Framework 기본값
# ------------------------------------------------------------
: "${SLACK_EVENT_TAG:=salt/framework/async/done}"
: "${FRAMEWORK_RUN_ID:=manual_$(date '+%Y%m%d%H%M%S')_$$}"
: "${FRAMEWORK_TASK_NAME:=unknown_task}"
: "${FRAMEWORK_BASE_DIR:=unknown_base_dir}"

if [[ -z "${FRAMEWORK_STARTED_AT:-}" ]]; then
    FRAMEWORK_STARTED_AT="$(date '+%F %T')"
fi

if [[ -z "${FRAMEWORK_STARTED_EPOCH:-}" ]]; then
    FRAMEWORK_STARTED_EPOCH="$(date +%s)"
fi

# ------------------------------------------------------------
# 기존 post 스타일 호환용 dummy slack 변수
# ------------------------------------------------------------
# remote에서 아래처럼 쓸 수 있게 만든다.
#
#   webhook=$slack4
#   message_send "$webhook" "$title" "$content"
#
# 여기서 slack4 값은 실제 webhook URL이 아니다.
# minion에서는 webhook URL을 가지면 안 된다.
# slack4 값은 master listener에게 전달할 target 이름이다.
# 실제 webhook URL은 master의 /data/salt/common/send_to_slack 안에서 찾는다.
# ------------------------------------------------------------
for (( __salt_framework_slack_i=1; __salt_framework_slack_i<=99; __salt_framework_slack_i++ )); do
    printf -v "slack${__salt_framework_slack_i}" '%s' "slack${__salt_framework_slack_i}"
done
unset __salt_framework_slack_i

# ------------------------------------------------------------
# salt-call 경로 확인
# ------------------------------------------------------------
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

    bin="$(command -v salt-call 2>/dev/null || true)"

    if [[ -n "$bin" && -x "$bin" ]]; then
        printf '%s\n' "$bin"
        return 0
    fi

    printf '%s\n' "salt-call"
    return 0
}

# ------------------------------------------------------------
# minion id 확인
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# Slack 알림 event 전송 함수
# ------------------------------------------------------------
# 기존 post 스타일 호환:
#
#   webhook=$slack4
#   message_send "$webhook" "$title" "$content"
#
# 확장 사용:
#
#   message_send "$webhook" "$title" "$content" "success" 0
#   message_send "$webhook" "$title" "$content" "failed" 1
#
# 동작:
#   - webhook_target 이 비어 있으면 아무것도 보내지 않고 정상 종료한다.
#   - webhook_target 은 slack숫자 형식만 허용한다.
#   - 실제 Slack webhook URL은 minion에 존재하지 않는다.
#   - master listener가 slack_target 값을 보고 send_to_slack 안의 slackN을 찾는다.
# ------------------------------------------------------------
message_send() {
    local webhook_target="${1:-}"
    local slack_title="${2:-Salt ASYNC 작업 완료}"
    local slack_content="${3:-}"
    local status="${4:-success}"
    local exit_code="${5:-0}"
    local ended_at=""
    local now_epoch=""
    local duration_sec=0
    local minion_id=""
    local tag="${SLACK_EVENT_TAG:-salt/framework/async/done}"
    local salt_call_bin=""

    # webhook target이 없으면 알림을 보내지 않는다.
    # async 작업 중 Slack 알림을 안 쓰는 remote도 있으므로 정상 종료 처리한다.
    if [[ -z "$webhook_target" ]]; then
        return 0
    fi

    # webhook=$slack4 또는 message_send "slack4" 형태만 허용한다.
    if [[ ! "$webhook_target" =~ ^slack[0-9]+$ ]]; then
        echo "message_send skip: webhook target 형식이 아닙니다: $webhook_target" >&2
        return 0
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

    python3 - "$salt_call_bin" \
        "$tag" \
        "$webhook_target" \
        "$FRAMEWORK_RUN_ID" \
        "$FRAMEWORK_TASK_NAME" \
        "$FRAMEWORK_BASE_DIR" \
        "$minion_id" \
        "$status" \
        "$exit_code" \
        "$FRAMEWORK_STARTED_AT" \
        "$ended_at" \
        "$duration_sec" \
        "$slack_title" \
        "$slack_content" <<'PY'
import json
import os
import socket
import subprocess
import sys
import time

salt_call_bin = sys.argv[1]
tag = sys.argv[2]
slack_target = sys.argv[3]
run_id = sys.argv[4]
task_name = sys.argv[5]
base_dir = sys.argv[6]
minion_id = sys.argv[7]
status = sys.argv[8]
exit_code_raw = sys.argv[9]
started_at = sys.argv[10]
ended_at = sys.argv[11]
duration_sec_raw = sys.argv[12]
slack_title = sys.argv[13]
slack_content = sys.argv[14]

try:
    exit_code = int(exit_code_raw)
except Exception:
    exit_code = 0

try:
    duration_sec = int(duration_sec_raw)
except Exception:
    duration_sec = 0

data = {
    "run_id": run_id,
    "task_name": task_name,
    "base_dir": base_dir,
    "minion_id": minion_id,
    "status": status,
    "exit_code": exit_code,
    "started_at": started_at,
    "ended_at": ended_at,
    "duration_sec": duration_sec,
    "slack_target": slack_target,
    "slack_title": slack_title,
    "slack_content": slack_content,
}

exec_master = os.environ.get("FRAMEWORK_EXEC_MASTER", "").strip()
exec_master_ips_raw = os.environ.get("FRAMEWORK_EXEC_MASTER_IPS", "").strip()

# 구버전 payload 호환용. 새 start.sh/salt_apply 에서는 FRAMEWORK_EXEC_MASTER_IPS 를 사용한다.
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
            text=True,
            timeout=15,
        )

        if proc.returncode == 0 and proc.stdout.strip():
            data = json.loads(proc.stdout)
            return flatten_master_values(data)
    except Exception:
        pass

    try:
        proc = subprocess.run(
            [salt_call_bin, "--local", "config.get", "master", "--out=txt"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
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

payload = json.dumps(data, ensure_ascii=False)

cmd = [salt_call_bin]

if matched_exec_master_ip:
    cmd.append(f"--master={matched_exec_master_ip}")

cmd.extend(["event.send", tag, payload, "--out=quiet"])

for attempt in range(1, 6):
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        if proc.returncode == 0:
            sys.exit(0)

    except Exception:
        pass

    time.sleep(10)

# 알림 실패가 원래 작업 결과를 망치지 않게 0 종료
sys.exit(0)
PY
}

# ------------------------------------------------------------
# long_message_send 호환
# ------------------------------------------------------------
# 기존 send_to_slack 에 long_message_send 를 쓰던 작업도
# async remote에서 동일하게 사용할 수 있게 alias 처리한다.
# ------------------------------------------------------------
long_message_send() {
    message_send "$@"
}

# ------------------------------------------------------------
# 명시적 함수명도 제공
# ------------------------------------------------------------
# 사용자가 나중에 더 명확한 이름으로 쓰고 싶을 때 사용 가능.
# 기존 호환을 위해 message_send 가 기본이다.
# ------------------------------------------------------------
send_salt_slack_event() {
    message_send "$@"
}

