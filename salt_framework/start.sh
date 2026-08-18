#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 기본 옵션
# ============================================================
# AUTO_YES=1 이면 실행 확인 질문 없이 바로 실행
# KEEP_TMP=1 이면 종료 후 .tmp 디렉토리 삭제하지 않음
AUTO_YES=0
KEEP_TMP=0
CLI_DEBUG=0
INIT_MODE=0
JID_QUERY_MODE=0
JID_QUERY_VALUE=""
JID_KILL_MODE=0
JID_KILL_VALUE=""
init_target=""

# ============================================================
# config 로드 기준
# ============================================================
# sage 인자 또는 현재 디렉토리를 기준으로 작업 디렉토리를 결정하고,
# 해당 작업 디렉토리의 config 파일을 로드한다.
#
# 사용 예:
#   sage -y
#   sage -y cron/작업분류/작업명
#
# cron 예:
#   * * * * /usr/local/bin/sage -y cron/작업분류/작업명
#
# 중요한 점:
#   - framework_dir은 공통 프레임워크 소스 위치다.
#   - base_dir은 sage 인자 또는 현재 디렉토리로 결정되는 실제 작업 디렉토리다.
#   - config를 source 한 뒤에도 모든 파일과 디렉토리는
#     sage/start.sh가 결정한 $base_dir 기준으로 처리한다.
#
# config 로드 후 기준 경로:
#   $base_dir/config
#   $base_dir/pre
#   $base_dir/local
#   $base_dir/remote
#   $base_dir/post
#   $base_dir/server
#   $framework_dir/salt_apply
#   $base_dir/log/server_fail
#   $base_dir/log/log_salt
#   $base_dir/log/debug.log
#   $base_dir/.tmp/result_status
#   $base_dir/result/*
#   $base_dir/error/*
# ============================================================

# ============================================================
# config 로드 기준 / 고정 경로
# ============================================================
# start.sh는 공통 프레임워크 디렉토리에 위치한다.
framework_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 공통 Salt 자동화 루트 고정
home_dir="/data/salt"

# Salt file_roots 역할 apply 디렉토리 고정
apply_dir="$home_dir/apply"

# sage에서 작업 경로를 넘기거나, 직접 실행 시 인자로 작업 경로를 받을 수 있다.
target_path="${SAGE_BASE_DIR:-}"

# ============================================================
# 사용법 출력
# ============================================================
print_usage() {
    cat <<'EOF'
==========================================================================
사용법
==========================================================================

  실행 : sage [실행옵션] [작업경로]
  생성 : sage -i|--init <작업경로>
  조회 : sage -j [JID|all]
  중단 : sage -K [JID]

경로를 생략하면 현재 디렉토리를 작업 디렉토리로 사용합니다.


실행 옵션:
  -y, --yes            실행 확인 없이 바로 실행
  --keep-tmp           실행 종료 후 .tmp 디렉토리 유지
  -d, --debug          debug.log 기록 및 디버그 내용 화면 출력

생성:
  -i, --init <경로>    sample을 복사해 작업 디렉토리 생성

조회:
  -j, --jid             현재 작업 경로의 실행 중 Sage JID 조회
  -j, --jid <JID>       지정한 JID의 현재 실행 상태 조회
  -j, --jid all         master의 전체 실행 중 Salt JID 조회

중단:
  -K, --kill-jid        현재 작업 경로의 실행 중 Sage JID 중단
  -K, --kill-jid <JID>  지정한 JID 중단

기타:
  -h, --help           도움말 출력


==========================================================================
config 주요 설정
==========================================================================

  TIMEOUT                    Salt 명령 통신 timeout(초)
                             기본값: 3

  SKIP_PING                  실행 전 전체 대상 서버의 test.ping 확인 생략
                             true/false, 기본값: false

  ASYNC                      Salt job 등록 후 결과를 기다리지 않고 종료
                             true/false, 기본값: false
                             true이면 result/error 생성 및 post 실행 안 함

  ASYNC_RESULT               비동기 작업 완료 결과를 event로 수집
                             true/false, 기본값: false
                             minion 작업 완료 시 result/error를 개별 생성
                             수집 로그: /var/log/salt/framework_event_listener.log

  COLLECT_BY_JID             JID 기반 결과 수집 사용 여부
                             true/false, 기본값: true
                             true : 대상이 많거나 결과 내용이 큰 작업에 권장
                             false: 대상과 결과 내용이 모두 작은 작업에 적합

  JID_CHUNK_SIZE             대상을 지정한 서버 수 단위로 분할 실행
                             기본값: 미설정
                             미설정: 대상이 200대 초과하면 200 자동 적용
                             빈 값/0: 자동 분할 해제
                             양의 정수: 지정한 서버 수 단위로 분할
                             기본적으로 대상 목록을 랜덤 셔플 후 분할

  JID_CHUNK_RANDOMIZE        JID_CHUNK_SIZE 분할 전 대상 목록 랜덤 셔플
                             true/false, 기본값: true
                             false: 정렬된 최종 server 목록 순서대로 분할

  JOB_WAIT_TIMEOUT           JID 작업 완료 대기시간(초)
                             기본값: 300
                             0: 완료될 때까지 제한 없이 대기
                             Salt job cache 보관시간을 초과하면
                             최종 결과를 수집하지 못할 수 있음

  BATCH                      기존 stdout 수집 방식의 batch 크기
                             기본값: 미사용
                             COLLECT_BY_JID=false일 때만 적용

  FILE_DEPLOY_WAIT_TIMEOUT   file_deploy 결과 대기시간(초)
                             기본값: 7200


==========================================================================
실행 모드 조합
==========================================================================

사용 가능 조합:
  1. 일반 작업 · 권장
     별도 설정 없음

     기본 JID 결과 수집을 사용하며,
     대상이 200대 초과하면 200대씩 자동 분할합니다.

  2. 소규모 · 결과 내용이 작은 작업
     COLLECT_BY_JID="false"

  3. job 등록 후 즉시 종료
     ASYNC="true"

     result/error 생성 및 post 실행을 하지 않습니다.

  4. 비동기 결과 event 수집
     ASYNC="true"
     ASYNC_RESULT="true"

     cmd.run + __RUN_SCRIPT__ 실행에서만 사용할 수 있습니다.


사용 불가 조합:
  ASYNC_RESULT="true" + ASYNC="false"
  ASYNC_RESULT="true" + cmd.run/__RUN_SCRIPT__ 외 실행 방식
  JID_CHUNK_SIZE="양의 정수" + ASYNC="true"
  JID_CHUNK_SIZE="양의 정수" + COLLECT_BY_JID="false"


참고:
  BATCH는 ASYNC="false" + COLLECT_BY_JID="false" 조합에서만 적용됩니다.
EOF
}

# ============================================================
# -i / --init : sample 디렉토리 복사로 신규 작업 디렉토리 생성
# ============================================================
# common/sample 디렉토리를 통째로 복사해 새 작업 디렉토리를 만든다.
# 작업명은 현재 디렉토리 기준 상대경로 또는 절대경로로 지정한다.
#   cd /data/salt/manual/108231ju; sage -i backup
#       -> /data/salt/manual/108231ju/backup
#   sage -i /data/salt/cron/daily/clean   (절대경로)
# 이미 존재하는 경로에는 생성하지 않는다(기존 작업 보호).
# ============================================================
init_job_dir() {
    local name="$1"
    local sample_dir="$home_dir/common/sample"
    local dest_dir

    if [[ -z "$name" ]]; then
        echo "작업 경로가 필요합니다."
        echo
        print_usage
        exit 1
    fi

    # 옵션 문자열을 작업 경로로 잘못 받은 경우 방어
    if [[ "$name" == -* ]]; then
        echo "작업 경로가 필요합니다: sage -i <작업경로>"
        exit 1
    fi

    if [[ ! -d "$sample_dir" ]]; then
        echo "sample 디렉토리 없음: $sample_dir"
        exit 1
    fi

    if [[ "$name" = /* ]]; then
        dest_dir="$name"
    else
        # 현재 디렉토리 기준으로 생성
        dest_dir="$(pwd -P)/$name"
    fi

    if [[ -e "$dest_dir" ]]; then
        echo "이미 존재합니다: $dest_dir"
        echo "다른 작업명을 사용하거나 기존 디렉토리를 확인하세요."
        exit 1
    fi

    mkdir -p "$(dirname "$dest_dir")"

    # 권한/타임스탬프까지 그대로 복사
    cp -a "$sample_dir" "$dest_dir"

    echo "=========================================================================="
    echo "신규 작업 디렉토리 생성 완료"
    echo "=========================================================================="
    echo "  원본 : $sample_dir"
    echo "  생성 : $dest_dir"
    echo "--------------------------------------------------------------------------"
    echo "다음 파일을 작업에 맞게 수정하세요:"
    echo "  README : 작업 기본 정보(작업명/설명/작성자 등)"
    echo "  config : Salt 실행 옵션"
    echo "  pre    : (선택) 실행 전 사전 작업 및 server 목록 생성"
    echo "  remote : 대상 서버에서 실행할 명령"
    echo "  local  : (선택) Salt 실행 전 master 로컬 작업"
    echo "  post   : (선택) 실행 결과 정리 후 후처리"
    echo "--------------------------------------------------------------------------"
    echo "실행 예: cd $dest_dir && sage"
    echo "=========================================================================="
}


# ============================================================
# Sage JID history
#
# history 규칙:
#   SALT_RC 없음  : JID 생성
#   SALT_RC=0     : 정상 완료
#   SALT_RC=1     : 실패
#   SALT_RC=130   : Ctrl+C / sage -K 취소
#   SALT_RC=143   : SIGTERM 취소
#
# JID 하나당 CREATE 1줄 + FINAL 1줄까지만 기록한다.
# CREATE 시간은 JID timestamp를 KST로 변환하고,
# FINAL 시간은 상태가 확정된 시각을 사용한다.
# ============================================================
__sage_jid_history_time() {
    local jid="${1:-}"
    local jid_utc=""

    if [[ "$jid" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2}) ]]; then
        jid_utc="$(
            printf '%s-%s-%s %s:%s:%s UTC' \
                "${BASH_REMATCH[1]}" \
                "${BASH_REMATCH[2]}" \
                "${BASH_REMATCH[3]}" \
                "${BASH_REMATCH[4]}" \
                "${BASH_REMATCH[5]}" \
                "${BASH_REMATCH[6]}"
        )"

        TZ=Asia/Seoul date -d "$jid_utc" '+%F %T' 2>/dev/null && return 0
    fi

    date '+%F %T'
}

append_sage_jid_history() {
    local jid="${1:-}"
    local context="${2:-}"
    local label="${3:-}"
    local target_count="${4:-unknown}"
    local rc="${5:-}"
    local history_time="${6:-}"
    local history_job="${7:-${SAGE_JOB_DIR:-${base_dir:-$(pwd -P)}}}"

    local history_dir="/var/log/salt"
    local history_log="$history_dir/sage_history.log"
    local history_lock="${history_log}.lock"
    local history_type=""
    local record_kind="create"

    [[ "$jid" =~ ^[0-9]+$ ]] || return 0

    if [[ -z "$context" ]]; then
        if [[ "${SALT_APPLY_CONTEXT:-default}" == "file_deploy" ]]; then
            context="file_deploy"
            label="${SAGE_FILE_DEPLOY_LABEL:-0000}:${JID_CHUNK_LABEL:-0/0}"
        elif [[ "${JID_CHUNK_ACTIVE:-0}" == "1" ]]; then
            context="chunk"
            label="${JID_CHUNK_LABEL:-0/0}"
        else
            context="main"
            label="-"
        fi
    fi

    case "$context" in
        file_deploy)
            history_type="FILE_DEPLOY"
            ;;
        chunk)
            history_type="JID_CHUNK"
            ;;
        main)
            history_type="MAIN"
            label="-"
            ;;
        *)
            return 0
            ;;
    esac

    [[ -n "$label" ]] || label="-"
    [[ -n "$target_count" ]] || target_count="unknown"

    if [[ -n "$rc" ]]; then
        record_kind="final"
    fi

    if [[ -z "$history_time" ]]; then
        if [[ "$record_kind" == "create" ]]; then
            history_time="$(__sage_jid_history_time "$jid")"
        else
            history_time="$(date '+%F %T')"
        fi
    fi

    mkdir -p "$history_dir" 2>/dev/null || return 0

    (
        flock -x 200

        # 같은 JID의 CREATE/FINAL은 각각 한 번만 기록한다.
        if [[ -s "$history_log" ]] &&
            awk -F '\t' \
                -v target_jid="JID: $jid" \
                -v record_kind="$record_kind" '
                    {
                        has_jid = 0
                        has_rc = 0

                        for (i = 1; i <= NF; i++) {
                            if ($i == target_jid) {
                                has_jid = 1
                            }

                            if ($i ~ /^SALT_RC:[[:space:]]*/) {
                                has_rc = 1
                            }
                        }

                        if (has_jid) {
                            if (record_kind == "create" && !has_rc) {
                                found = 1
                            }

                            if (record_kind == "final" && has_rc) {
                                found = 1
                            }
                        }
                    }

                    END {
                        exit(found ? 0 : 1)
                    }
                ' "$history_log"
        then
            exit 0
        fi

        if [[ "$record_kind" == "create" ]]; then
            printf '%s\tJOB: %s\tTYPE: %s\tLABEL: %s\tJID: %s\tTARGETS: %s\n' \
                "$history_time" \
                "$history_job" \
                "$history_type" \
                "$label" \
                "$jid" \
                "$target_count" \
                >> "$history_log"
        else
            printf '%s\tJOB: %s\tTYPE: %s\tLABEL: %s\tJID: %s\tTARGETS: %s\tSALT_RC: %s\n' \
                "$history_time" \
                "$history_job" \
                "$history_type" \
                "$label" \
                "$jid" \
                "$target_count" \
                "$rc" \
                >> "$history_log"
        fi
    ) 200>"$history_lock" 2>/dev/null || true

    return 0
}

# ============================================================
# JID 실행 상태 조회 (-j / --jid)
# ============================================================
# 조회 모드는 일반 Sage 실행과 완전히 분리한다.
# config/pre/server/ping/.run.lock을 읽거나 생성하지 않는다.
#
#   sage -j
#     현재 작업 디렉토리의 log/jid_registry에 기록된 JID만 대상으로
#     saltutil.find_job을 실행하여 현재 실행 중인 Sage JID를 출력한다.
#
#   sage -j <JID>
#     현재 디렉토리의 jid_registry에 해당 JID가 있으면 그 대상만 조회하고,
#     없으면 master job cache(jobs.list_job)에서 대상 minion을 확인한 뒤
#     해당 대상에게만 saltutil.find_job을 실행한다.
#
# jobs.active는 모든 minion의 saltutil.running을 조회하므로 사용하지 않는다.
# JID는 숫자로 변환하지 않고 문자열 그대로 처리한다.
# ============================================================
resolve_salt_bin_for_jid_query() {
    local bin="${SALT_BIN:-}"

    if [[ -n "$bin" && -x "$bin" ]]; then
        printf '%s\n' "$bin"
        return 0
    fi

    if [[ -x /usr/bin/salt ]]; then
        printf '%s\n' "/usr/bin/salt"
        return 0
    fi

    bin="$(command -v salt 2>/dev/null || true)"

    if [[ -n "$bin" && -x "$bin" ]]; then
        printf '%s\n' "$bin"
        return 0
    fi

    return 1
}

resolve_salt_run_bin_for_jid_query() {
    local bin="${SALT_RUN_BIN:-}"

    if [[ -n "$bin" && -x "$bin" ]]; then
        printf '%s\n' "$bin"
        return 0
    fi

    if [[ -x /usr/bin/salt-run ]]; then
        printf '%s\n' "/usr/bin/salt-run"
        return 0
    fi

    bin="$(command -v salt-run 2>/dev/null || true)"

    if [[ -n "$bin" && -x "$bin" ]]; then
        printf '%s\n' "$bin"
        return 0
    fi

    return 1
}

jid_query_targets_to_file() {
    local targets="$1"
    local output_file="$2"

    printf '%s\n' "$targets" \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | sed '/^$/d' \
        | sort -u \
        > "$output_file"
}

jid_query_json_keys() {
    local json_file="$1"
    local mode="$2"

    python3 - "$json_file" "$mode" <<'PY_JID_FIND_KEYS'
import json
import sys

path = sys.argv[1]
mode = sys.argv[2]

try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)

for host, value in data.items():
    # saltutil.find_job 정상 응답:
    #   {}        = 해당 JID가 현재 실행 중이 아님
    #   non-empty = 해당 JID가 현재 실행 중
    # timeout/error 문자열 등은 정상 상태 응답으로 보지 않는다.
    if mode == "responded":
        if isinstance(value, dict):
            print(host)
    elif mode == "active":
        if isinstance(value, dict) and value:
            print(host)
PY_JID_FIND_KEYS
}

jid_query_find_state() {
    local jid="$1"
    local targets="$2"
    local state_dir="$3"

    local salt_bin=""
    local timeout_bin=""
    local salt_timeout="${JID_QUERY_SALT_TIMEOUT:-3}"
    local hard_timeout="${JID_QUERY_HARD_TIMEOUT:-15}"
    local chunk_size="${JID_QUERY_TARGET_CHUNK_SIZE:-200}"
    local expected_file="$state_dir/expected"
    local responded_file="$state_dir/responded"
    local active_file="$state_dir/active"
    local inactive_file="$state_dir/inactive"
    local unknown_file="$state_dir/unknown"
    local chunk_dir="$state_dir/chunks"
    local chunk_file=""
    local chunk_targets=""
    local json_file=""
    local err_file=""
    local rc=0

    if [[ ! "$salt_timeout" =~ ^[0-9]+$ ]] || (( salt_timeout < 1 )); then
        echo "JID_QUERY_SALT_TIMEOUT 값이 올바르지 않습니다: $salt_timeout" >&2
        return 1
    fi

    if [[ ! "$hard_timeout" =~ ^[0-9]+$ ]] || (( hard_timeout < 1 )); then
        echo "JID_QUERY_HARD_TIMEOUT 값이 올바르지 않습니다: $hard_timeout" >&2
        return 1
    fi

    if [[ ! "$chunk_size" =~ ^[0-9]+$ ]] || (( chunk_size < 1 )); then
        echo "JID_QUERY_TARGET_CHUNK_SIZE 값이 올바르지 않습니다: $chunk_size" >&2
        return 1
    fi

    if ! salt_bin="$(resolve_salt_bin_for_jid_query)"; then
        echo "salt 명령을 찾을 수 없습니다." >&2
        return 1
    fi

    timeout_bin="$(command -v timeout 2>/dev/null || true)"

    rm -rf "$state_dir"
    mkdir -p "$state_dir" "$chunk_dir"

    jid_query_targets_to_file "$targets" "$expected_file"

    : > "$responded_file"
    : > "$active_file"
    : > "$inactive_file"
    : > "$unknown_file"

    if [[ ! -s "$expected_file" ]]; then
        return 0
    fi

    split -d -a 5 -l "$chunk_size" "$expected_file" "$chunk_dir/chunk_"

    for chunk_file in "$chunk_dir"/chunk_*; do
        [[ -s "$chunk_file" ]] || continue

        chunk_targets="$(paste -sd, "$chunk_file")"
        json_file="${chunk_file}.json"
        err_file="${chunk_file}.err"

        set +e
        if [[ -n "$timeout_bin" ]]; then
            "$timeout_bin" \
                --signal=TERM \
                --kill-after=2 \
                "${hard_timeout}s" \
                "$salt_bin" \
                -t "$salt_timeout" \
                --out=json \
                --static \
                -L "$chunk_targets" \
                saltutil.find_job "$jid" \
                > "$json_file" \
                2> "$err_file"
            rc=$?
        else
            "$salt_bin" \
                -t "$salt_timeout" \
                --out=json \
                --static \
                -L "$chunk_targets" \
                saltutil.find_job "$jid" \
                > "$json_file" \
                2> "$err_file"
            rc=$?
        fi
        set -e

        # Salt CLI rc가 비정상이어도 정상 JSON으로 돌아온 minion은 살린다.
        if jid_query_json_keys "$json_file" responded >> "$responded_file" 2>/dev/null; then
            jid_query_json_keys "$json_file" active >> "$active_file" 2>/dev/null || true
        fi

        : "$rc"
    done

    sort -u -o "$responded_file" "$responded_file"
    sort -u -o "$active_file" "$active_file"

    comm -23 "$responded_file" "$active_file" > "$inactive_file"
    comm -23 "$expected_file" "$responded_file" > "$unknown_file"

    return 0
}

jid_query_get_registry_record() {
    local registry_file="$1"
    local target_jid="$2"

    [[ -s "$registry_file" ]] || return 1

    awk -F '\t' -v target_jid="$target_jid" '
        ($4 "") == (target_jid "") && $4 ~ /^[0-9]+$/ && $6 != "" {
            print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6
            exit
        }
    ' "$registry_file"
}

jid_query_get_job_cache_info() {
    local jid="$1"
    local output_file="$2"
    local error_file="$3"
    local salt_run_bin=""
    local timeout_bin=""
    local hard_timeout="${JID_QUERY_RUNNER_HARD_TIMEOUT:-15}"
    local rc=0

    if [[ ! "$hard_timeout" =~ ^[0-9]+$ ]] || (( hard_timeout < 1 )); then
        echo "JID_QUERY_RUNNER_HARD_TIMEOUT 값이 올바르지 않습니다: $hard_timeout" >&2
        return 1
    fi

    if ! salt_run_bin="$(resolve_salt_run_bin_for_jid_query)"; then
        echo "salt-run 명령을 찾을 수 없습니다." >&2
        return 1
    fi

    timeout_bin="$(command -v timeout 2>/dev/null || true)"

    set +e
    if [[ -n "$timeout_bin" ]]; then
        "$timeout_bin" \
            --signal=TERM \
            --kill-after=2 \
            "${hard_timeout}s" \
            "$salt_run_bin" jobs.list_job "$jid" --out=json \
            > "$output_file" \
            2> "$error_file"
        rc=$?
    else
        "$salt_run_bin" jobs.list_job "$jid" --out=json \
            > "$output_file" \
            2> "$error_file"
        rc=$?
    fi
    set -e

    if [[ "$rc" -ne 0 ]]; then
        echo "JID 정보 조회 실패: salt-run jobs.list_job rc=$rc" >&2
        if [[ -s "$error_file" ]]; then
            sed 's/^/  /' "$error_file" >&2
        fi
        return 1
    fi

    return 0
}

jid_query_parse_job_cache_info() {
    local cache_json="$1"

    python3 - "$cache_json" <<'PY_JID_CACHE'
import json
import sys

path = sys.argv[1]

try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

if isinstance(data, dict) and "return" in data and len(data) == 1 and isinstance(data["return"], dict):
    data = data["return"]

if not isinstance(data, dict):
    sys.exit(1)

if data.get("Error"):
    sys.exit(2)

function = data.get("Function", "")
target_type = str(data.get("Target-type", "list") or "list")
minions = data.get("Minions", [])
target = data.get("Target", "")

hosts = []
seen = set()

def add(value):
    value = str(value).strip()
    if value and value not in seen:
        seen.add(value)
        hosts.append(value)

if isinstance(minions, (list, tuple)):
    for item in minions:
        add(item)

# Sage가 발급한 JID는 -L list target이므로 Minions가 없을 때
# Target-type=list의 Target을 안전한 fallback으로 사용한다.
if not hosts and target_type == "list":
    if isinstance(target, str):
        for item in target.split(","):
            add(item)
    elif isinstance(target, (list, tuple)):
        for item in target:
            add(item)

if not hosts:
    sys.exit(3)

print(str(function).replace("\t", " ").replace("\n", " "))
print(",".join(hosts))
PY_JID_CACHE
}

jid_query_format_type() {
    local context="$1"

    case "$context" in
        main) printf '%s\n' "MAIN" ;;
        chunk) printf '%s\n' "JID_CHUNK" ;;
        file_deploy) printf '%s\n' "FILE_DEPLOY" ;;
        *) printf '%s\n' "${context^^}" ;;
    esac
}

jid_query_get_history_record() {
    local jid="$1"
    local history_log="/var/log/salt/sage_history.log"

    [[ -s "$history_log" ]] || return 1

    awk -F '\t' -v target_jid="JID: $jid" '
        {
            has_jid = 0
            job = ""
            type = ""
            label = ""
            targets = ""
            rc = ""

            for (i = 1; i <= NF; i++) {
                if ($i == target_jid) {
                    has_jid = 1
                } else if ($i ~ /^JOB:[[:space:]]*/) {
                    job = $i
                    sub(/^JOB:[[:space:]]*/, "", job)
                } else if ($i ~ /^TYPE:[[:space:]]*/) {
                    type = $i
                    sub(/^TYPE:[[:space:]]*/, "", type)
                } else if ($i ~ /^LABEL:[[:space:]]*/) {
                    label = $i
                    sub(/^LABEL:[[:space:]]*/, "", label)
                } else if ($i ~ /^TARGETS:[[:space:]]*/) {
                    targets = $i
                    sub(/^TARGETS:[[:space:]]*/, "", targets)
                } else if ($i ~ /^SALT_RC:[[:space:]]*/) {
                    rc = $i
                    sub(/^SALT_RC:[[:space:]]*/, "", rc)
                }
            }
            if (has_jid) {
                matched = job "\t" type "\t" label "\t" targets "\t" rc
            }
        }

        END {
            if (matched != "") {
                print matched
            } else {
                exit 1
            }
        }
    ' "$history_log"
}

jid_query_specific() {
    local jid="$1"
    local work_dir="$2"
    local current_registry="$(pwd -P)/log/jid_registry"
    local registry_record=""
    local history_record=""
    local context=""
    local label="-"
    local target_count="?"
    local targets=""
    local function=""
    local job="-"
    local type_name="-"
    local history_type=""
    local history_label=""
    local history_targets=""
    local history_rc=""
    local cache_json="$work_dir/job_cache.json"
    local cache_err="$work_dir/job_cache.err"
    local -a cache_info=()
    local cache_info_file="$work_dir/cache_info"
    local state_dir="$work_dir/state"
    local active_count=0
    local unknown_count=0
    local cache_parse_rc=0

    # --------------------------------------------------------
    # 현재 작업 디렉토리의 jid_registry에서 먼저 조회
    # --------------------------------------------------------
    registry_record="$(
        jid_query_get_registry_record \
            "$current_registry" \
            "$jid" \
            2>/dev/null || true
    )"

    if [[ -n "$registry_record" ]]; then
        IFS=$'\t' read -r \
            context \
            label \
            _jid \
            target_count \
            targets <<< "$registry_record"

        job="$(pwd -P)"
        type_name="$(jid_query_format_type "$context")"

    else
        # ----------------------------------------------------
        # 현재 작업의 registry에 없으면 master job cache 조회
        # ----------------------------------------------------
        if ! jid_query_get_job_cache_info \
            "$jid" \
            "$cache_json" \
            "$cache_err"
        then
            echo "JID 상태를 확인할 수 없습니다: $jid"
            return 1
        fi

        set +e
        jid_query_parse_job_cache_info \
            "$cache_json" \
            > "$cache_info_file"
        cache_parse_rc=$?
        set -e

        if [[ "$cache_parse_rc" -eq 0 ]]; then
            mapfile -t cache_info < "$cache_info_file"
        fi

        # job cache에 없으면 현재 실행 중인 JID가 아님
        if [[ "$cache_parse_rc" -eq 2 ]]; then
            echo "실행 중인 JID가 아닙니다: $jid"
            return 0
        fi

        if [[ "$cache_parse_rc" -ne 0 || ${#cache_info[@]} -lt 2 ]]; then
            echo "JID 상태를 확인할 수 없습니다: $jid"
            return 1
        fi

        function="${cache_info[0]}"
        targets="${cache_info[1]}"

        target_count="$(
            printf '%s\n' "$targets" \
                | tr ',' '\n' \
                | sed '/^$/d' \
                | sort -u \
                | wc -l
        )"
    fi

    # --------------------------------------------------------
    # sage_history에서 JOB / TYPE / LABEL / TARGETS 보강
    # --------------------------------------------------------
    history_record="$(
        jid_query_get_history_record \
            "$jid" \
            2>/dev/null || true
    )"

    if [[ -n "$history_record" ]]; then
        IFS=$'\t' read -r \
            job \
            history_type \
            history_label \
            history_targets \
            history_rc <<< "$history_record"

        if [[ -n "$history_type" ]]; then
            type_name="$history_type"
        fi

        if [[ -n "$history_label" ]]; then
            label="$history_label"
        fi

        if [[ "$history_targets" =~ ^[0-9]+$ ]]; then
            target_count="$history_targets"
        fi
    fi

    # --------------------------------------------------------
    # 실제 minion에서 해당 JID 실행 상태 조회
    # --------------------------------------------------------
    if ! jid_query_find_state \
        "$jid" \
        "$targets" \
        "$state_dir"
    then
        echo "JID 상태를 확인할 수 없습니다: $jid"
        return 1
    fi

    active_count="$(wc -l < "$state_dir/active")"
    unknown_count="$(wc -l < "$state_dir/unknown")"

    # --------------------------------------------------------
    # 실행 중
    # --------------------------------------------------------
    if (( active_count > 0 )); then
        printf 'JID      : %s\n' "$jid"
        printf 'JOB      : %s\n' "$job"
        printf 'TYPE     : %s\n' "$type_name"

        if [[ "${label:--}" != "-" ]]; then
            printf 'LABEL    : %s\n' "$label"
        fi

        if [[ -n "$function" ]]; then
            printf 'FUNCTION : %s\n' "$function"
        fi

        echo "STATUS   : RUNNING"
        printf 'RUNNING  : %s대\n' "$active_count"

        if [[ "$target_count" =~ ^[0-9]+$ ]]; then
            printf 'TARGETS  : %s대\n' "$target_count"
        fi

        if (( unknown_count > 0 )); then
            printf 'UNKNOWN  : %s대\n' "$unknown_count"
        fi

        return 0
    fi

    # --------------------------------------------------------
    # 실행 중인 host는 없지만 일부 host 상태 확인 실패
    # --------------------------------------------------------
    if (( unknown_count > 0 )); then
        echo "JID 상태를 확인할 수 없습니다: $jid"
        return 1
    fi

    # --------------------------------------------------------
    # 전체 대상에서 find_job={} 확인 → 실행 종료
    # --------------------------------------------------------
    echo "실행 중인 JID가 아닙니다: $jid"
    return 0
}

jid_query_current_job() {
    local work_dir="$1"
    local job_dir="$(pwd -P)"
    local registry_file="$job_dir/log/jid_registry"
    local records_file="$work_dir/registry_records"
    local history_record=""
    local context=""
    local label=""
    local jid=""
    local target_count=""
    local targets=""
    local state_dir=""
    local active_count=0
    local unknown_count=0
    local running_jid_count=0
    local unknown_jid_count=0
    local type_name=""
    local job="$job_dir"
    local history_type=""
    local history_label=""
    local history_targets=""
    local history_rc=""

    if [[ ! -s "$registry_file" ]]; then
        echo "현재 작업 디렉토리에 조회할 Sage JID가 없습니다."
        echo "확인 경로: $registry_file"
        return 0
    fi

    awk -F '\t' '
        $4 ~ /^[0-9]+$/ && $6 != "" && !seen[$4]++ {
            print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6
        }
    ' "$registry_file" > "$records_file"

    if [[ ! -s "$records_file" ]]; then
        echo "현재 작업 디렉토리에 유효한 Sage JID가 없습니다."
        return 0
    fi

    while IFS=$'\t' read -r context label jid target_count targets; do
        [[ "$jid" =~ ^[0-9]+$ ]] || continue
        [[ -n "$targets" ]] || continue

        state_dir="$work_dir/state_$jid"

        if ! jid_query_find_state "$jid" "$targets" "$state_dir"; then
            unknown_jid_count=$((unknown_jid_count + 1))
            continue
        fi

        active_count="$(wc -l < "$state_dir/active")"
        unknown_count="$(wc -l < "$state_dir/unknown")"

        # 실행 중이 아닌 JID는 출력하지 않는다.
        if (( active_count == 0 )); then
            if (( unknown_count > 0 )); then
                unknown_jid_count=$((unknown_jid_count + 1))
            fi
            continue
        fi

        job="$job_dir"
        type_name="$(jid_query_format_type "$context")"

        history_record="$(jid_query_get_history_record "$jid" 2>/dev/null || true)"

        if [[ -n "$history_record" ]]; then
            IFS=$'\t' read -r \
                job \
                history_type \
                history_label \
                history_targets \
                history_rc <<< "$history_record"

            [[ -n "$history_type" ]] && type_name="$history_type"
            [[ -n "$history_label" ]] && label="$history_label"

            if [[ "$history_targets" =~ ^[0-9]+$ ]]; then
                target_count="$history_targets"
            fi
        fi

        if (( running_jid_count == 0 )); then
            echo "[ 실행 중인 Sage JID ]"
            echo
        else
            echo
        fi

        running_jid_count=$((running_jid_count + 1))

        printf 'JID      : %s\n' "$jid"
        printf 'JOB      : %s\n' "$job"
        printf 'TYPE     : %s\n' "$type_name"

        if [[ "${label:--}" != "-" ]]; then
            printf 'LABEL    : %s\n' "$label"
        fi

        echo "STATUS   : RUNNING"
        printf 'RUNNING  : %s대\n' "$active_count"
        printf 'TARGETS  : %s대\n' "${target_count:-?}"

        if (( unknown_count > 0 )); then
            printf 'UNKNOWN  : %s대\n' "$unknown_count"
        fi

    done < "$records_file"

    if (( running_jid_count == 0 )); then
        echo "실행 중인 Sage JID가 없습니다."
    else
        echo
        printf '실행 중 JID : %s개\n' "$running_jid_count"
    fi

    if (( unknown_jid_count > 0 )); then
        printf '상태 미확인 JID : %s개\n' "$unknown_jid_count"
    fi

    return 0
}

jid_query_all_active() {
    local work_dir="$1"
    local salt_run_bin=""
    local timeout_bin=""
    local hard_timeout="${JID_QUERY_RUNNER_HARD_TIMEOUT:-15}"
    local output_file="$work_dir/jobs_active.json"
    local error_file="$work_dir/jobs_active.err"
    local history_log="/var/log/salt/sage_history.log"
    local rc=0
    local parse_rc=0

    if [[ ! "$hard_timeout" =~ ^[0-9]+$ ]] || (( hard_timeout < 1 )); then
        echo "JID_QUERY_RUNNER_HARD_TIMEOUT 값이 올바르지 않습니다: $hard_timeout" >&2
        return 1
    fi

    if ! salt_run_bin="$(resolve_salt_run_bin_for_jid_query)"; then
        echo "salt-run 명령을 찾을 수 없습니다." >&2
        return 1
    fi

    timeout_bin="$(command -v timeout 2>/dev/null || true)"

    set +e
    if [[ -n "$timeout_bin" ]]; then
        "$timeout_bin" \
            --signal=TERM \
            --kill-after=2 \
            "${hard_timeout}s" \
            "$salt_run_bin" jobs.active --out=json \
            > "$output_file" \
            2> "$error_file"
        rc=$?
    else
        "$salt_run_bin" jobs.active --out=json \
            > "$output_file" \
            2> "$error_file"
        rc=$?
    fi
    set -e

    if [[ "$rc" -ne 0 ]]; then
        echo "전체 JID 조회 실패: salt-run jobs.active rc=$rc" >&2
        if [[ -s "$error_file" ]]; then
            sed 's/^/  /' "$error_file" >&2
        fi
        return 1
    fi

    set +e
    python3 - "$output_file" "$history_log" <<'PY_JID_ACTIVE_ALL'
import json
import re
import sys

jobs_path = sys.argv[1]
history_path = sys.argv[2]

try:
    with open(jobs_path, "r", encoding="utf-8", errors="replace") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

if (
    isinstance(data, dict)
    and set(data.keys()) == {"return"}
    and isinstance(data["return"], dict)
):
    data = data["return"]

if not isinstance(data, dict):
    sys.exit(1)

history = {}

history_pattern = re.compile(
    r"JOB:\s*(.*?)\s+"
    r"TYPE:\s*(.*?)\s+"
    r"LABEL:\s*(.*?)\s+"
    r"JID:\s*(\d+)\s+"
    r"TARGETS:\s*(\S+)"
    r"(?:\s+SALT_RC:\s*(\S+))?"
)

try:
    with open(history_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            match = history_pattern.search(line.rstrip("\n"))

            if not match:
                continue

            job, job_type, label, jid, targets, _rc = match.groups()

            history[jid] = {
                "job": job,
                "type": job_type,
                "label": label,
                "targets": targets,
            }
except Exception:
    pass

jobs = []

for jid, info in data.items():
    jid = str(jid).strip()

    if not jid.isdigit() or not isinstance(info, dict):
        continue

    running = info.get("Running", {})

    if isinstance(running, dict):
        running_count = len(running)
    elif isinstance(running, (list, tuple, set)):
        running_count = len(running)
    elif running in (None, ""):
        running_count = 0
    else:
        running_count = 1

    if running_count <= 0:
        continue

    function = (
        str(info.get("Function", "-") or "-")
        .replace("\n", " ")
        .replace("\t", " ")
    )

    hist = history.get(jid, {})

    job = hist.get("job", "-")
    job_type = hist.get("type", "-")
    label = hist.get("label", "-")
    target_count = hist.get("targets", "")

    if not str(target_count).isdigit():
        target = info.get("Target", "")
        target_type = str(info.get("Target-type", "") or "")
        target_items = []

        if target_type == "list":
            if isinstance(target, str):
                target_items = [
                    item.strip()
                    for item in target.split(",")
                    if item.strip()
                ]
            elif isinstance(target, (list, tuple)):
                target_items = [
                    str(item).strip()
                    for item in target
                    if str(item).strip()
                ]

        target_count = len(target_items) if target_items else ""

    jobs.append(
        (
            jid,
            job,
            job_type,
            label,
            function,
            running_count,
            target_count,
        )
    )

if not jobs:
    print("실행 중인 Salt JID가 없습니다.")
    sys.exit(0)

jobs.sort(key=lambda item: item[0], reverse=True)

print("[ 실행 중인 전체 Salt JID ]")

for (
    jid,
    job,
    job_type,
    label,
    function,
    running_count,
    target_count,
) in jobs:
    print()
    print(f"JID      : {jid}")
    print(f"JOB      : {job}")
    print(f"TYPE     : {job_type}")

    if label != "-":
        print(f"LABEL    : {label}")

    print(f"FUNCTION : {function}")
    print(f"RUNNING  : {running_count}대")

    if str(target_count).isdigit():
        print(f"TARGETS  : {target_count}대")

print()
print(f"실행 중 JID : {len(jobs)}개")
PY_JID_ACTIVE_ALL

    parse_rc=$?
    set -e

    if [[ "$parse_rc" -ne 0 ]]; then
        echo "전체 JID 조회 결과를 해석할 수 없습니다." >&2
        return 1
    fi

    return 0
}

run_jid_query_mode() {
    local jid="${1:-}"
    local work_dir=""
    local rc=0

    work_dir="$(mktemp -d /tmp/sage_jid_query.XXXXXX)"

    set +e
    if [[ "$jid" == "all" ]]; then
        jid_query_all_active "$work_dir"
        rc=$?
    elif [[ -n "$jid" ]]; then
        jid_query_specific "$jid" "$work_dir"
        rc=$?
    else
        jid_query_current_job "$work_dir"
        rc=$?
    fi
    set -e

    rm -rf -- "$work_dir"
    return "$rc"
}

# ============================================================
# JID 강제 중단 (-K / --kill-jid)
# ============================================================

jid_kill_run_lock_held() {
    local lock_file="$1"
    local fd=""

    [[ -e "$lock_file" ]] || return 1

    exec {fd}<>"$lock_file" || return 1

    if flock -n "$fd"; then
        flock -u "$fd" 2>/dev/null || true
        exec {fd}>&-
        return 1
    fi

    exec {fd}>&-
    return 0
}


jid_kill_signal_hosts() {
    local jid="$1"
    local host_file="$2"
    local function_name="$3"
    local work_dir="$4"

    local salt_bin=""
    local timeout_bin=""
    local salt_timeout="${CANCEL_SALT_TIMEOUT:-2}"
    local hard_timeout="${CANCEL_COMMAND_HARD_TIMEOUT:-8}"
    local chunk_size="${CANCEL_TARGET_CHUNK_SIZE:-200}"

    local chunk_dir="$work_dir/${function_name}"
    local chunk_file=""
    local chunk_targets=""
    local rc=0

    [[ -s "$host_file" ]] || return 0

    if ! salt_bin="$(resolve_salt_bin_for_jid_query)"; then
        echo "salt 명령을 찾을 수 없습니다." >&2
        return 1
    fi

    timeout_bin="$(command -v timeout 2>/dev/null || true)"

    rm -rf "$chunk_dir"
    mkdir -p "$chunk_dir"

    split -d -a 5 -l "$chunk_size" \
        "$host_file" \
        "$chunk_dir/chunk_"

    for chunk_file in "$chunk_dir"/chunk_*; do
        [[ -s "$chunk_file" ]] || continue

        chunk_targets="$(paste -sd, "$chunk_file")"

        set +e

        if [[ -n "$timeout_bin" ]]; then
            "$timeout_bin" \
                --signal=TERM \
                --kill-after=2 \
                "${hard_timeout}s" \
                "$salt_bin" \
                -t "$salt_timeout" \
                --out=json \
                --static \
                -L "$chunk_targets" \
                "saltutil.${function_name}" "$jid" \
                > "${chunk_file}.out" \
                2> "${chunk_file}.err"
            rc=$?
        else
            "$salt_bin" \
                -t "$salt_timeout" \
                --out=json \
                --static \
                -L "$chunk_targets" \
                "saltutil.${function_name}" "$jid" \
                > "${chunk_file}.out" \
                2> "${chunk_file}.err"
            rc=$?
        fi

        set -e

        : "$rc"
    done

    return 0
}


jid_kill_one() {
    local jid="$1"
    local targets="$2"
    local work_dir="$3"
    local job="$4"
    local type_name="$5"
    local label="$6"
    local target_count="$7"
    local function_name="${8:-}"

    local jid_dir="$work_dir/jid_$jid"
    local before_dir="$jid_dir/before"
    local after_term_dir="$jid_dir/after_term"
    local final_dir="$jid_dir/final"
    local unknown_file="$jid_dir/unknown"

    local active_before=0
    local unknown_before=0
    local active_after_term=0
    local active_final=0
    local unknown_total=0

    local after_term_targets=""
    local final_targets=""

    local term_wait="${CANCEL_TERM_WAIT:-2}"
    local kill_wait="${CANCEL_KILL_WAIT:-1}"

    mkdir -p "$jid_dir"

    if ! jid_query_find_state \
        "$jid" \
        "$targets" \
        "$before_dir"
    then
        return 3
    fi

    active_before="$(wc -l < "$before_dir/active")"
    unknown_before="$(wc -l < "$before_dir/unknown")"

    # 실행 중인 대상 없음
    if (( active_before == 0 )); then
        if (( unknown_before > 0 )); then
            return 3
        fi

        return 2
    fi

    # --------------------------------------------------------
    # TERM
    # --------------------------------------------------------
    jid_kill_signal_hosts \
        "$jid" \
        "$before_dir/active" \
        "term_job" \
        "$jid_dir"

    sleep "$term_wait"

    after_term_targets="$(
        paste -sd, "$before_dir/active" 2>/dev/null || true
    )"

    jid_query_find_state \
        "$jid" \
        "$after_term_targets" \
        "$after_term_dir"

    active_after_term="$(wc -l < "$after_term_dir/active")"

    # --------------------------------------------------------
    # TERM 이후에도 실행 중이면 KILL
    # --------------------------------------------------------
    if (( active_after_term > 0 )); then
        jid_kill_signal_hosts \
            "$jid" \
            "$after_term_dir/active" \
            "kill_job" \
            "$jid_dir"

        sleep "$kill_wait"
    fi

    final_targets="$(
        paste -sd, "$after_term_dir/active" 2>/dev/null || true
    )"

    jid_query_find_state \
        "$jid" \
        "$final_targets" \
        "$final_dir"

    active_final="$(wc -l < "$final_dir/active")"

    {
        cat "$before_dir/unknown" 2>/dev/null
        cat "$after_term_dir/unknown" 2>/dev/null
        cat "$final_dir/unknown" 2>/dev/null
    } |
        sed '/^[[:space:]]*$/d' |
        sort -u \
        > "$unknown_file"

    unknown_total="$(wc -l < "$unknown_file")"

    if [[ "${JID_KILL_HEADER_PRINTED:-0}" -eq 0 ]]; then
        echo "[ Sage JID 강제 중단 ]"
        echo
        JID_KILL_HEADER_PRINTED=1
    else
        echo
    fi

    printf 'JID      : %s\n' "$jid"
    printf 'JOB      : %s\n' "$job"
    printf 'TYPE     : %s\n' "$type_name"

    if [[ "${label:--}" != "-" ]]; then
        printf 'LABEL    : %s\n' "$label"
    fi

    if [[ -n "$function_name" && "$type_name" == "-" ]]; then
        printf 'FUNCTION : %s\n' "$function_name"
    fi

    if (( active_final > 0 )); then
        echo "STATUS   : RUNNING"
        printf 'RUNNING  : %s대\n' "$active_final"

    elif (( unknown_total > 0 )); then
        echo "STATUS   : UNKNOWN"
        printf 'UNKNOWN  : %s대\n' "$unknown_total"

    else
        echo "STATUS   : STOPPED"
    fi

    if [[ "$target_count" =~ ^[0-9]+$ ]]; then
        printf 'TARGETS  : %s대\n' "$target_count"
    fi

    if (( active_final > 0 || unknown_total > 0 )); then
        return 1
    fi

    # Sage JID인 경우에만 취소 완료 history를 기록한다.
    # 임의의 일반 Salt JID(-K <JID>)는 sage_history에 넣지 않는다.
    case "$type_name" in
        MAIN)
            append_sage_jid_history \
                "$jid" "main" "-" "$target_count" "130" "" "$job"
            ;;
        JID_CHUNK)
            append_sage_jid_history \
                "$jid" "chunk" "$label" "$target_count" "130" "" "$job"
            ;;
        FILE_DEPLOY)
            append_sage_jid_history \
                "$jid" "file_deploy" "$label" "$target_count" "130" "" "$job"
            ;;
    esac

    return 0
}


jid_kill_current_job() {
    local work_dir="$1"

    local job_dir="$(pwd -P)"
    local registry_file="$job_dir/log/jid_registry"
    local lock_file="$job_dir/.run.lock"
    local tmp_dir="$job_dir/.tmp"
    local pending_file="$tmp_dir/async_pending"
    local protect_marker="$tmp_dir/jid_registering"
    local cancel_marker="$tmp_dir/cancelled"

    local records_file="$work_dir/registry_records"

    local controller_running=0
    local cancel_marker_created=0
    local run_id="external-K"

    local record_run_id=""
    local context=""
    local label=""
    local jid=""
    local target_count=""
    local targets=""
    local type_name=""

    local rc=0
    local kill_count=0
    local fail_count=0
    local unknown_count=0
    local i=0

    # --------------------------------------------------------
    # Sage 본체가 실행 중인지 확인
    # --------------------------------------------------------
    if jid_kill_run_lock_held "$lock_file"; then
        controller_running=1
    fi

    # --------------------------------------------------------
    # 현재 run_id 확인
    # --------------------------------------------------------
    if [[ -s "$registry_file" ]]; then
        run_id="$(
            awk -F '\t' '
                $1 != "" {
                    run_id=$1
                }
                END {
                    if (run_id != "")
                        print run_id
                }
            ' "$registry_file"
        )"
    elif [[ -s "$pending_file" ]]; then
        IFS=$'\t' read -r run_id _rest < "$pending_file" || true
    fi

    [[ -n "$run_id" ]] || run_id="external-K"

    # --------------------------------------------------------
    # 현재 Sage가 실행 중이거나 ASYNC_RESULT가 수집 중이면
    # cancelled marker를 먼저 만든다.
    #
    # 이렇게 해야 FILE_DEPLOY -> REMOTE 사이의 JID 없는 구간에서도
    # 다음 JID 제출을 차단할 수 있다.
    # --------------------------------------------------------
    if (( controller_running == 1 )) || [[ -s "$pending_file" ]]; then
        mkdir -p "$tmp_dir"

        if [[ ! -s "$cancel_marker" ]]; then
            printf '%s\trun_id=%s\tsignal=EXTERNAL_K\n' \
                "$(date '+%F %T')" \
                "$run_id" \
                > "$cancel_marker"
        fi

        cancel_marker_created=1

        # JID가 발급되어 registry 기록 중이면 완료까지 잠시 기다린다.
        for ((i=0; i<100; i++)); do
            [[ ! -e "$protect_marker" ]] && break
            sleep 0.1
        done
    fi

    # --------------------------------------------------------
    # marker 생성 이후 registry snapshot
    # --------------------------------------------------------
    if [[ -s "$registry_file" ]]; then
        awk -F '\t' '
            $4 ~ /^[0-9]+$/ &&
            $6 != "" &&
            !seen[$4]++ {
                print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6
            }
        ' "$registry_file" |
            tac \
            > "$records_file"
    else
        : > "$records_file"
    fi

    while IFS=$'\t' read -r \
        record_run_id \
        context \
        label \
        jid \
        target_count \
        targets
    do
        [[ "$jid" =~ ^[0-9]+$ ]] || continue
        [[ -n "$targets" ]] || continue

        type_name="$(jid_query_format_type "$context")"

        if jid_kill_one \
            "$jid" \
            "$targets" \
            "$work_dir" \
            "$job_dir" \
            "$type_name" \
            "$label" \
            "$target_count" \
            ""

		then
		    rc=0
		else
		    rc=$?
		fi

        case "$rc" in
            0)
                kill_count=$((kill_count + 1))
                ;;
            1)
                kill_count=$((kill_count + 1))
                fail_count=$((fail_count + 1))
                ;;
            2)
                ;;
            3)
                unknown_count=$((unknown_count + 1))
                ;;
        esac

    done < "$records_file"

    # --------------------------------------------------------
    # ASYNC_RESULT는 Sage 프로세스가 이미 종료된 상태일 수 있다.
    #
    # 이 경우에는 cleanup을 실행할 Sage가 없으므로,
    # 모든 JID 종료가 확인됐다면 여기서 .tmp를 정리한다.
    # --------------------------------------------------------
    if (( controller_running == 0 )) &&
       (( cancel_marker_created == 1 )) &&
       (( fail_count == 0 )) &&
       (( unknown_count == 0 ))
    then
        rm -rf "$tmp_dir"

        if [[ "$run_id" != "external-K" ]]; then
            rm -rf "$apply_dir/sage_file_deploy/$run_id"
            rmdir "$apply_dir/sage_file_deploy" 2>/dev/null || true
        fi
    fi

    if (( kill_count > 0 )); then
        echo
        printf '중단 처리 JID : %s개\n' "$kill_count"

        if (( fail_count > 0 )); then
            printf '종료 미확인 JID : %s개\n' "$fail_count"
        fi

        if (( unknown_count > 0 )); then
            printf '상태 미확인 JID : %s개\n' "$unknown_count"
        fi

        if (( fail_count > 0 || unknown_count > 0 )); then
            return 1
        fi

        return 0
    fi

    # JID는 없지만 Sage controller가 살아 있는 공백 구간
    if (( controller_running == 1 )); then
        echo "Sage 취소 요청을 등록했습니다."
        echo "후속 Salt JID 제출을 차단합니다."
        return 0
    fi

    if (( unknown_count > 0 )); then
        echo "Sage JID 상태를 확인할 수 없습니다."
        printf '상태 미확인 JID : %s개\n' "$unknown_count"
        return 1
    fi

    echo "실행 중인 Sage JID가 없습니다."
    return 0
}


jid_kill_specific() {
    local jid="$1"
    local work_dir="$2"

    local current_registry="$(pwd -P)/log/jid_registry"

    local registry_record=""
    local history_record=""

    local context=""
    local registry_label=""
    local registry_target_count=""
    local _jid=""

    local label="-"
    local target_count="?"
    local targets=""

    local job="-"
    local type_name="-"
    local function_name=""

    local history_type="-"
    local history_label="-"
    local history_targets="?"
    local history_rc="?"

    local cache_json="$work_dir/job_cache.json"
    local cache_err="$work_dir/job_cache.err"
    local cache_info_file="$work_dir/cache_info"
    local cache_parse_rc=0
    local -a cache_info=()

    local rc=0

    # history 정보
    history_record="$(
        jid_query_get_history_record \
            "$jid" \
            2>/dev/null || true
    )"

    if [[ -n "$history_record" ]]; then
        IFS=$'\t' read -r \
            job \
            history_type \
            history_label \
            history_targets \
            history_rc <<< "$history_record"

        type_name="$history_type"
        label="$history_label"

        if [[ "$history_targets" =~ ^[0-9]+$ ]]; then
            target_count="$history_targets"
        fi
    fi

    # 현재 작업 registry
    registry_record="$(
        jid_query_get_registry_record \
            "$current_registry" \
            "$jid" \
            2>/dev/null || true
    )"

    if [[ -n "$registry_record" ]]; then
        IFS=$'\t' read -r \
            context \
            registry_label \
            _jid \
            registry_target_count \
            targets <<< "$registry_record"

        if [[ "$job" == "-" ]]; then
            job="$(pwd -P)"
        fi

        if [[ "$type_name" == "-" ]]; then
            type_name="$(jid_query_format_type "$context")"
        fi

        if [[ "$label" == "-" && -n "$registry_label" ]]; then
            label="$registry_label"
        fi

        if [[ "$target_count" == "?" &&
              "$registry_target_count" =~ ^[0-9]+$ ]]
        then
            target_count="$registry_target_count"
        fi

    else
        # 현재 디렉토리 registry에 없으면 master job cache에서 대상 조회
        if ! jid_query_get_job_cache_info \
            "$jid" \
            "$cache_json" \
            "$cache_err"
        then
            echo "JID 상태를 확인할 수 없습니다: $jid"
            return 1
        fi

        set +e

        jid_query_parse_job_cache_info \
            "$cache_json" \
            > "$cache_info_file"

        cache_parse_rc=$?

        set -e

        if [[ "$cache_parse_rc" -eq 2 ]]; then
            echo "실행 중인 JID가 아닙니다: $jid"
            return 0
        fi

        if [[ "$cache_parse_rc" -ne 0 ]]; then
            echo "JID 상태를 확인할 수 없습니다: $jid"
            return 1
        fi

        mapfile -t cache_info < "$cache_info_file"

        if [[ ${#cache_info[@]} -lt 2 ]]; then
            echo "JID 상태를 확인할 수 없습니다: $jid"
            return 1
        fi

        function_name="${cache_info[0]}"
        targets="${cache_info[1]}"

        if [[ "$target_count" == "?" ]]; then
            target_count="$(
                printf '%s\n' "$targets" |
                    tr ',' '\n' |
                    sed '/^$/d' |
                    sort -u |
                    wc -l
            )"
        fi
    fi

    if jid_kill_one \
        "$jid" \
        "$targets" \
        "$work_dir" \
        "$job" \
        "$type_name" \
        "$label" \
        "$target_count" \
        "$function_name"

	then
		rc=0
	else
		rc=$?
	fi

    case "$rc" in
        0)
            return 0
            ;;
        1)
            return 1
            ;;
        2)
            echo "실행 중인 JID가 아닙니다: $jid"
            return 0
            ;;
        3)
            echo "JID 상태를 확인할 수 없습니다: $jid"
            return 1
            ;;
    esac

    return 1
}


run_jid_kill_mode() {
    local jid="${1:-}"
    local work_dir=""
    local pending_file=""
    local pending_jid=""
    local rc=0

    work_dir="$(mktemp -d /tmp/sage_jid_kill.XXXXXX)"

    JID_KILL_HEADER_PRINTED=0

	if [[ -n "$jid" ]]; then
        pending_file="$(pwd -P)/.tmp/async_pending"
        pending_jid=""

        if [[ -s "$pending_file" ]]; then
            pending_jid="$(awk -F '\t' 'NR == 1 {print $4}' "$pending_file")"
        fi

        if [[ "$pending_jid" == "$jid" ]]; then
            if jid_kill_current_job "$work_dir"; then
                rc=0
            else
                rc=$?
            fi
        else
            if jid_kill_specific "$jid" "$work_dir"; then
                rc=0
            else
                rc=$?
            fi
        fi
	else
	    if jid_kill_current_job "$work_dir"; then
	        rc=0
	    else
	        rc=$?
	    fi
	fi

    rm -rf -- "$work_dir"

    return "$rc"
}

# ============================================================
# 실행 옵션 처리
# ============================================================
while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
        -y|--yes)
            AUTO_YES=1
            ;;
        --keep-tmp)
            KEEP_TMP=1
            ;;
        -d|--debug)
            CLI_DEBUG=1
            ;;
        -i|--init)
            INIT_MODE=1
            # -i 다음 인자를 작업 경로로 사용(있을 때만 소비)
            if [[ $# -ge 2 ]]; then
                init_target="$2"
                shift
            fi
            ;;
        -j|--jid)
            JID_QUERY_MODE=1
            # 다음 값이 옵션이 아니면 JID로 사용한다.
            # 생략하면 현재 작업 디렉토리의 jid_registry를 조회한다.
            if [[ $# -ge 2 && "$2" != -* ]]; then
                JID_QUERY_VALUE="$2"
                shift
            fi
            ;;
        -K|--kill-jid)
            JID_KILL_MODE=1

            # 생략하면 현재 작업 전체 취소
            # JID가 있으면 해당 JID만 중단
            if [[ $# -ge 2 && "$2" != -* ]]; then
                JID_KILL_VALUE="$2"
                shift
            fi
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        -*)
            echo "알 수 없는 옵션: $arg"
            exit 1
            ;;
        *)
            if [[ -n "$target_path" ]]; then
                echo "작업 경로는 하나만 지정할 수 있습니다: $target_path / $arg"
                exit 1
            fi
            target_path="$arg"
            ;;
    esac
    shift
done

# ============================================================
# -K / --kill-jid 처리
# ============================================================
if [[ "$JID_QUERY_MODE" -eq 1 && "$JID_KILL_MODE" -eq 1 ]]; then
    echo "-j/--jid와 -K/--kill-jid는 같이 사용할 수 없습니다."
    exit 1
fi

if [[ "$JID_KILL_MODE" -eq 1 ]]; then
    if [[ "$INIT_MODE" -eq 1 ||
          "$AUTO_YES" -eq 1 ||
          "$KEEP_TMP" -eq 1 ||
          "$CLI_DEBUG" -eq 1 ||
          -n "$target_path" ]]
    then
        echo "-K/--kill-jid 옵션은 일반 실행 옵션 또는 작업 경로와 같이 사용할 수 없습니다."
        exit 1
    fi

    if [[ "$JID_KILL_VALUE" == "all" ]]; then
        echo "-K all은 지원하지 않습니다."
        exit 1
    fi

    if [[ -n "$JID_KILL_VALUE" &&
          ! "$JID_KILL_VALUE" =~ ^[0-9]+$ ]]
    then
        echo "JID 값이 올바르지 않습니다: $JID_KILL_VALUE"
        exit 1
    fi

    run_jid_kill_mode "$JID_KILL_VALUE"
    exit $?
fi

# ============================================================
# -j / --jid 처리: JID 실행 상태 조회 후 종료
# ============================================================
if [[ "$JID_QUERY_MODE" -eq 1 ]]; then
    if [[ "$INIT_MODE" -eq 1 || "$AUTO_YES" -eq 1 || "$KEEP_TMP" -eq 1 || "$CLI_DEBUG" -eq 1 || -n "$target_path" ]]; then
        echo "-j/--jid 옵션은 일반 실행 옵션 또는 작업 경로와 같이 사용할 수 없습니다."
        exit 1
    fi

    if [[ -n "$JID_QUERY_VALUE" && "$JID_QUERY_VALUE" != "all" && ! "$JID_QUERY_VALUE" =~ ^[0-9]+$ ]]; then
        echo "JID 값이 올바르지 않습니다: $JID_QUERY_VALUE"
        echo "사용 가능 값: 숫자 JID, all"
        exit 1
    fi

    run_jid_query_mode "$JID_QUERY_VALUE"
    exit $?
fi

# ============================================================
# -i / --init 처리: 신규 작업 디렉토리 생성 후 종료
# ============================================================
# config나 server 로딩 등 실제 Salt 실행 로직보다 먼저 처리하고 종료한다.
# (신규 작업은 아직 config가 없으므로 이후 단계로 진행하면 안 된다.)
if [[ "$INIT_MODE" -eq 1 ]]; then
    init_job_dir "$init_target"
    exit 0
fi

if [[ -z "$target_path" ]]; then
    target_path="$(pwd -P)"
fi

if [[ "$target_path" = /* ]]; then
    target_dir="$target_path"
else
    target_dir="$home_dir/$target_path"
fi

if [[ ! -d "$target_dir" ]]; then
    echo "작업 디렉토리 없음: $target_dir"
    exit 1
fi

base_dir="$(cd "$target_dir" && pwd)"
config_file="$base_dir/config"

# ============================================================
# 작업 파일 Bash 문법 검사
# ============================================================
# config/pre/local/remote/post는 Bash 기반 파일이므로
# config source 및 server/minion 처리 전에 bash -n으로 검사한다.
# 하나라도 문법 오류가 있으면 전체 오류를 출력한 뒤 실행을 중단한다.
# ============================================================
validate_job_bash_syntax() {
    local -a check_names=("config" "pre" "local" "remote" "post")
    local -a error_names=()
    local -a error_messages=()
    local name=""
    local file=""
    local syntax_error=""
    local line=""
    local i=0
    local first_line=0

    for name in "${check_names[@]}"; do
        file="$base_dir/$name"

        # config는 아래에서 필수 파일 여부를 별도로 검사한다.
        # pre/local/remote/post는 파일이 있을 때만 문법 검사한다.
        [[ -f "$file" ]] || continue

        if ! syntax_error="$(bash -n "$file" 2>&1)"; then
            error_names+=("$name")
            error_messages+=("$syntax_error")
        fi
    done

    if (( ${#error_names[@]} == 0 )); then
        return 0
    fi

    echo
    echo "[ bash -n 오류 ]"

    for (( i=0; i<${#error_names[@]}; i++ )); do
        first_line=1

        while IFS= read -r line; do
            if [[ "$first_line" -eq 1 ]]; then
                printf '%-7s: %s\n' "${error_names[$i]}" "$line"
                first_line=0
            else
                printf '         %s\n' "$line"
            fi
        done <<< "${error_messages[$i]}"

        echo
    done

    echo "Bash 문법 오류가 있어 sage 실행을 중단합니다."
    exit 1
}

# ============================================================
# config 로드 및 필수 변수 검증
# ============================================================
if [[ ! -f "$config_file" ]]; then
    echo "config 파일 없음: $config_file"
    exit 1
fi

# config/pre/local/remote/post Bash 문법 검사
# 오류가 있으면 config source 전에 실행을 중단한다.
validate_job_bash_syntax

# ============================================================
# config 직접 선언 옵션 확인
# ============================================================
# start.sh와 salt_apply에서 ${OPTION:-기본값} 형태로 사용하는
# 대문자 변수를 자동으로 찾는다.
#
# 이후 config에 직접 선언된 변수와 비교하여,
# 사용자가 config에 설정한 실행 옵션만 [ 실행 모드 ]에 출력한다.
#
# 신규 옵션이 프레임워크 소스에 추가돼도
# 별도의 옵션 목록을 수정할 필요가 없다.
# ============================================================
declare -A framework_config_option_set=()
declare -A config_declared_values=()

declare -a config_assigned_names=()
declare -a config_declared_options=()

prepare_config_option_detection() {
    local option_name=""

    # start.sh와 salt_apply에서
    # ${OPTION:-기본값}, ${OPTION:=기본값} 등의 형태로
    # 사용되는 대문자 변수명을 자동 추출한다.
    while IFS= read -r option_name; do
        [[ -z "$option_name" ]] && continue

        framework_config_option_set["$option_name"]=1
    done < <(
        grep -hoE \
            '\$\{[A-Z][A-Z0-9_]*:[-+=?]' \
            "$framework_dir/start.sh" \
            "$framework_dir/salt_apply" \
            2>/dev/null \
            | sed -E 's/^\$\{([A-Z][A-Z0-9_]*):.*/\1/' \
            | sort -u
    )

    # 작업 실행 정의값은 실행 옵션 목록에서 제외한다.
    unset 'framework_config_option_set[SALT_FUNCTION]'
    unset 'framework_config_option_set[SALT_ARGS]'
    unset 'framework_config_option_set[RUN_SCRIPT]'

    # config에 직접 선언된 대문자 변수명을
    # config 작성 순서대로 추출한다.
    mapfile -t config_assigned_names < <(
        sed -nE \
            's/^[[:space:]]*(export[[:space:]]+)?([A-Z][A-Z0-9_]*)[[:space:]]*=.*/\2/p' \
            "$config_file" \
            | awk '!seen[$0]++'
    )
}

capture_config_declared_options() {
    local option_name=""

    for option_name in "${config_assigned_names[@]}"; do
        # 프레임워크 소스에서 실제 옵션 형태로 사용되지 않으면 제외한다.
        if [[ -z "${framework_config_option_set[$option_name]:-}" ]]; then
            continue
        fi

        config_declared_options+=("$option_name")

        # config source 직후 값을 저장한다.
        # 이후 JID_CHUNK_SIZE=0 등이 내부에서 빈 값으로 변경돼도
        # config에 사용자가 설정한 값을 그대로 출력할 수 있다.
        config_declared_values["$option_name"]="${!option_name-}"
    done
}

# config source 전에
# 프레임워크 옵션 목록과 config 선언 변수 목록을 확인한다.
prepare_config_option_detection

# config 로드
source "$config_file"

# config에 직접 설정한 실행 옵션 값을 저장한다.
capture_config_declared_options

# config에 JID_CHUNK_SIZE를 직접 선언했는지 확인
jid_chunk_size_declared=0

if grep -Eq \
    '^[[:space:]]*(export[[:space:]]+)?JID_CHUNK_SIZE[[:space:]]*=' \
    "$config_file"
then
    jid_chunk_size_declared=1
fi

# config에 같은 변수가 남아 있어도 무시하고
# sage/start.sh 기준값으로 강제 고정한다.
base_dir="$(cd "$target_dir" && pwd)"
home_dir="/data/salt"
apply_dir="$home_dir/apply"

# config에서 반드시 정의되어야 하는 값
: "${home_dir:?home_dir 설정 실패}"
: "${base_dir:?base_dir 자동 설정 실패}"
: "${apply_dir:?apply_dir 설정 실패}"
: "${SALT_FUNCTION:?config에 SALT_FUNCTION 이 필요합니다}"

# ============================================================
# 내부 기본값
# ============================================================
TIMEOUT="${TIMEOUT:-3}"

if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]] || (( TIMEOUT < 1 )); then
    echo "TIMEOUT 값이 올바르지 않습니다: $TIMEOUT"
    echo "사용 가능 값: 1 이상의 정수"
    exit 1
fi

# ============================================================
# ASYNC_RESULT 실행 master 정보 확인
# ============================================================
# ASYNC_RESULT=true 인 경우 minion 완료 event를 실행 master로 보내야 하므로
# sage를 실행한 master의 IP 후보 목록을 확인한다.
# IP 대역은 하드코딩하지 않고 hostname -I 결과 전체를 사용한다.
# ============================================================
detect_framework_exec_master_info() {
    local attempt=0
    local master_ips=""

    FRAMEWORK_EXEC_MASTER="${FRAMEWORK_EXEC_MASTER:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown_master)}"

    if [[ -n "${FRAMEWORK_EXEC_MASTER_IPS:-}" ]]; then
        export FRAMEWORK_EXEC_MASTER
        export FRAMEWORK_EXEC_MASTER_IPS
        return 0
    fi

    while (( attempt < 3 )); do
        attempt=$((attempt + 1))

        master_ips="$(
            hostname -I 2>/dev/null \
                | awk '
                    {
                        for (i = 1; i <= NF; i++) {
                            if ($i != "" && !seen[$i]++) {
                                if (out == "") {
                                    out = $i
                                } else {
                                    out = out " " $i
                                }
                            }
                        }
                    }
                    END {
                        print out
                    }
                ' || true
        )"

        if [[ -n "$master_ips" ]]; then
            FRAMEWORK_EXEC_MASTER_IPS="$master_ips"
            export FRAMEWORK_EXEC_MASTER
            export FRAMEWORK_EXEC_MASTER_IPS
            return 0
        fi

        sleep 1
    done

    echo "FRAMEWORK_EXEC_MASTER_IPS 확인 실패: remote event.send 사용 작업이지만 hostname -I 결과가 비어있습니다."
    echo "event.send 대상 master를 결정할 수 없어 작업을 중단합니다."
    exit 1
}

# ============================================================
# 중복 실행 방지
# ============================================================
lock_file="${RUN_LOCK_FILE:-$base_dir/.run.lock}"
LOCK_ACQUIRED=0

exec 9>"$lock_file"

if ! flock -n 9; then
    echo "이미 실행 중입니다: $lock_file"
    exit 0
fi

LOCK_ACQUIRED=1

# lock 획득 이후 cleanup()이 등록되기 전에 종료되더라도
# .run.lock 파일이 남지 않도록 즉시 임시 EXIT trap을 등록한다.
# 아래에서 전체 cleanup()이 정의된 뒤 `trap cleanup EXIT`으로 교체된다.
trap '
    if [[ "${LOCK_ACQUIRED:-0}" -eq 1 && -n "${lock_file:-}" ]]; then
        rm -f "$lock_file"
    fi
' EXIT

# ============================================================
# 실행 산출물 디렉토리 초기화
# 중복 실행 lock을 잡은 뒤에만 지운다.
# ============================================================
log_dir="$base_dir/log"
result_dir="$base_dir/result"
error_dir="$base_dir/error"
tmp_dir="$base_dir/.tmp"

if [[ -s "$tmp_dir/async_pending" ]]; then
    echo "이전 ASYNC_RESULT 작업의 결과를 아직 수집 중입니다."
    echo "확인 경로: $tmp_dir/async_pending"
    exit 1
fi

rm -rf "$log_dir" "$result_dir" "$error_dir" "$tmp_dir"

mkdir -p "$log_dir"
mkdir -p "$result_dir"
mkdir -p "$error_dir"
mkdir -p "$tmp_dir"

# ============================================================
# 공통 화면 출력 형식
# ============================================================
SAGE_OUTPUT_LINE="=========================================================================="

sage_print_line() {
    printf '%s\n' "$SAGE_OUTPUT_LINE"
}

sage_print_section() {
    local title="$1"

    echo
    sage_print_line
    printf '[ %s ]\n\n' "$title"
}

sage_print_subsection() {
    local title="$1"

    printf '  [ %s ]\n\n' "$title"
}

# ============================================================
# CLI debug 옵션
# ============================================================
# config에는 디버그 옵션을 노출하지 않고, start.sh 실행 옵션으로만 켠다.
#   bash start.sh -d
#   bash start.sh --debug
#
# DEBUG_MODE=true  : salt_apply에서 debug.log 기록
# DEBUG_PRINT=true : debug 내용을 터미널에도 실시간 출력
# ============================================================
if [[ "$CLI_DEBUG" -eq 1 ]]; then
    DEBUG_MODE="true"
    DEBUG_PRINT="true"
fi

DEBUG_MODE="${DEBUG_MODE:-false}"
DEBUG_PRINT="${DEBUG_PRINT:-false}"

# 실행 산출물 로그 디렉토리
# jid_registry, debug.log, log_salt, server_fail 은 모두 이 디렉토리에 저장한다.
log_dir="${log_dir:-$base_dir/log}"
DEBUG_LOG="${DEBUG_LOG:-$log_dir/debug.log}"

# ============================================================
# dirty nodes 제외 파일
# ============================================================
# 운영자가 일시적으로 제외하고 싶은 서버 목록을 한 줄에 하나씩 기록한다.
# 예: /data/salt/common/dirty_nodes
#   mc77
#   m10
#   mb11
#
# 이 파일에 있는 host는 최종 실행 대상 server에서 제외하고,
# $log_dir/server_fail 에 <host>    dirty_nodes 형태로 기록한다.
# 기본 경로는 /data/salt/common/dirty_nodes이며,
# config에 DIRTY_NODES_FILE을 선언하면 경로를 변경할 수 있다.
# ============================================================
dirty_nodes_file="${DIRTY_NODES_FILE:-$home_dir/common/dirty_nodes}"

if [[ ! -d "$apply_dir" ]]; then
    echo "apply_dir 디렉토리 없음: $apply_dir"
    exit 1
fi

# SALT_ARGS 배열 존재 여부 확인
if ! declare -p SALT_ARGS >/dev/null 2>&1; then
    echo "config에 SALT_ARGS 가 필요합니다"
    exit 1
fi

# SALT_ARGS는 반드시 배열이어야 함
if [[ "$(declare -p SALT_ARGS)" != declare\ -a* && "$(declare -p SALT_ARGS)" != declare\ -A* ]]; then
    echo "SALT_ARGS 는 배열로 선언해야 합니다. 예: SALT_ARGS=(\"sample\")"
    exit 1
fi

# ============================================================
# ASYNC 옵션 검증
# true 계열이면 salt --async 모드
# false 계열 또는 미설정이면 기존 동기 실행
# ============================================================
case "${ASYNC:-false}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y)
        ;;
    false|FALSE|False|0|no|NO|No|n|N|"")
        ;;
    *)
        echo "ASYNC 값이 올바르지 않습니다: ${ASYNC}"
        echo "사용 가능 값: true, false"
        exit 1
        ;;
esac

# ============================================================
# COLLECT_BY_JID 옵션 검증
# true 계열이면 JID 기반 수집 모드
# false 계열이면 기존 stdout/log_salt 실시간 수집 모드
# ============================================================
case "${COLLECT_BY_JID:-true}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y)
        ;;
    false|FALSE|False|0|no|NO|No|n|N|"")
        ;;
    *)
        echo "COLLECT_BY_JID 값이 올바르지 않습니다: ${COLLECT_BY_JID}"
        echo "사용 가능 값: true, false"
        exit 1
        ;;
esac

# ============================================================
# ASYNC_RESULT 옵션 검증
# ============================================================
# 기본값은 false다.
# ASYNC_RESULT=true 는 ASYNC=true + cmd.run RUN_SCRIPT 모드에서만 사용한다.
# salt_apply의 framework wrapper가 remote의 stdout/stderr/exit code를
# 자동으로 수집해 event로 전송한다.
# remote에서는 event 전송 함수를 직접 호출하지 않는다.
# master listener는 result/error를 생성하고 전체 완료 후 post를 1회 실행한다.
# ============================================================
case "${ASYNC_RESULT:-false}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y)
        ;;
    false|FALSE|False|0|no|NO|No|n|N|"")
        ;;
    *)
        echo "ASYNC_RESULT 값이 올바르지 않습니다: ${ASYNC_RESULT}"
        echo "사용 가능 값: true, false"
        exit 1
        ;;
esac

case "${ASYNC_RESULT:-false}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y)
        case "${ASYNC:-false}" in
            true|TRUE|True|1|yes|YES|Yes|y|Y)
                ;;
            *)
                echo "ASYNC_RESULT 는 ASYNC=true 모드에서만 사용할 수 있습니다."
                echo
                echo "사유:"
                echo "  ASYNC_RESULT 는 비동기 Salt job의 결과를 event로 수집하는 옵션입니다."
                echo "  ASYNC=false 모드에서는 기존 JID/stdout 수집 후 run_post()가 result/error를 생성합니다."
                echo
                echo "조치:"
                echo "  1) async 결과 수집을 사용하려면 ASYNC=true 를 설정하세요."
                echo "  2) 동기 실행을 사용하려면 ASYNC_RESULT 를 비우거나 false로 설정하세요."
                exit 1
                ;;
        esac

        if [[ "${SALT_FUNCTION:-}" != "cmd.run" || "${SALT_ARGS[0]:-}" != "__RUN_SCRIPT__" ]]; then
            echo "ASYNC_RESULT 는 cmd.run + RUN_SCRIPT 모드에서만 사용할 수 있습니다."
            echo
            echo "필요 설정:"
            echo '  SALT_FUNCTION="cmd.run"'
            echo '  SALT_ARGS=("__RUN_SCRIPT__")'
            echo '  RUN_SCRIPT="$base_dir/remote"'
            exit 1
        fi

        if [[ -z "${EVENT_NOTIFY_LIB:-}" ]]; then
            if [[ -s "$framework_dir/salt_framework_event_notify.sh" ]]; then
                EVENT_NOTIFY_LIB="$framework_dir/salt_framework_event_notify.sh"
            else
                EVENT_NOTIFY_LIB="$home_dir/common/salt_framework_event_notify.sh"
            fi
        fi

        if [[ ! -s "$EVENT_NOTIFY_LIB" ]]; then
            echo "ASYNC_RESULT=true 모드는 EVENT_NOTIFY_LIB 파일이 필요합니다."
            echo "파일 없음 또는 비어있음: $EVENT_NOTIFY_LIB"
            exit 1
        fi
        ;;
esac

# ============================================================
# JID_CHUNK_SIZE 옵션 검증
#
# JID_CHUNK_SIZE
#   - config에 비어있거나 0으로 선언하면 청크 실행을 사용하지 않는다.
#   - config에 양의 정수를 선언하면 해당 개수 단위로 나눠 실행한다.
#   - config에 선언하지 않았고 최종 실행 대상이 200대를 초과하면
#     JID_CHUNK_SIZE=200을 자동 적용한다.
#   - 최종 server 목록을 랜덤 셔플한 뒤 청크 단위로 나눠
#     JID 기반으로 순차 실행한다.
#   - JID_CHUNK_RANDOMIZE=false이면 랜덤 셔플 없이
#     정렬된 최종 server 목록 순서대로 분할한다.
#
# 제한:
#   - ASYNC=true와 같이 사용할 수 없다.
#   - COLLECT_BY_JID=false와 같이 사용할 수 없다.
# ============================================================
case "${JID_CHUNK_SIZE:-}" in
    ""|0)
        JID_CHUNK_SIZE=""
        ;;
    *[!0-9]*)
        echo "JID_CHUNK_SIZE 값이 올바르지 않습니다: ${JID_CHUNK_SIZE}"
        echo "사용 가능 값: 비움, 0, 양의 정수"
        exit 1
        ;;
    *)
        if (( 10#$JID_CHUNK_SIZE < 1 )); then
            JID_CHUNK_SIZE=""
        fi
        ;;
esac

case "${JID_CHUNK_RANDOMIZE:-true}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y|"")
        JID_CHUNK_RANDOMIZE="true"
        ;;
    false|FALSE|False|0|no|NO|No|n|N)
        JID_CHUNK_RANDOMIZE="false"
        ;;
    *)
        echo "JID_CHUNK_RANDOMIZE 값이 올바르지 않습니다: ${JID_CHUNK_RANDOMIZE}"
        echo "사용 가능 값: true, false"
        exit 1
        ;;
esac

if [[ -n "${JID_CHUNK_SIZE:-}" ]]; then
    case "${ASYNC:-false}" in
        true|TRUE|True|1|yes|YES|Yes|y|Y)
            echo "JID_CHUNK_SIZE 는 ASYNC=true 모드에서 사용할 수 없습니다."
            echo
            echo "사유:"
            echo "  ASYNC=true 는 Salt job만 등록하고 결과를 기다리지 않는 모드입니다."
            echo "  JID_CHUNK_SIZE 는 청크별 JID 결과를 수집해야 하는 모드입니다."
            echo
            echo "조치:"
            echo "  1) 청크 실행을 사용하려면 ASYNC=false 로 변경하세요."
            echo "  2) job만 등록하려면 JID_CHUNK_SIZE 를 비우거나 0으로 설정하세요."
            exit 1
            ;;
    esac

    case "${COLLECT_BY_JID:-true}" in
        true|TRUE|True|1|yes|YES|Yes|y|Y)
            ;;
        *)
            echo "JID_CHUNK_SIZE 는 COLLECT_BY_JID=false 모드에서 사용할 수 없습니다."
            echo
            echo "사유:"
            echo "  JID_CHUNK_SIZE 는 salt --async 로 JID를 발급하고 jobs.lookup_jid 로 결과를 수집하는 모드입니다."
            echo "  COLLECT_BY_JID=false 는 기존 Salt stdout 수집 방식입니다."
            echo
            echo "조치:"
            echo "  1) 청크 실행을 사용하려면 COLLECT_BY_JID=true 로 변경하세요."
            echo "  2) 기존 stdout 방식을 사용하려면 JID_CHUNK_SIZE 를 비우거나 0으로 설정하세요."
            exit 1
            ;;
    esac
fi

# ============================================================
# file_deploy 내부 staging 경로
# ============================================================
# local의 file_deploy가 임의 경로의 파일을 Salt fileserver로 전달할 수 있도록
# apply_dir 아래에 실행 단위 staging 경로를 사용한다.
# 같은 파일시스템이면 hard link를 사용하고, 불가능할 때만 cp -p로 복사한다.
# ============================================================
sage_file_deploy_run_id="$(date '+%Y%m%d%H%M%S')_$$"
file_deploy_stage_root="$apply_dir/sage_file_deploy/$sage_file_deploy_run_id"

# ============================================================
# Sage 실행 단위 JID registry
#
# 현재 run에서 발급된 main/chunk/file_deploy JID를 발급 직후 기록한다.
# Ctrl+C/TERM 취소 시 이 파일만 기준으로 현재 Sage가 만든 JID를 선별한다.
# ============================================================
SAGE_RUN_ID="$sage_file_deploy_run_id"
JID_REGISTRY_FILE="$log_dir/jid_registry"
JID_REGISTRY_LOCK_FILE="$tmp_dir/jid_registry.lock"

: > "$JID_REGISTRY_FILE"

export SAGE_RUN_ID
export JID_REGISTRY_FILE
export JID_REGISTRY_LOCK_FILE

# ============================================================
# Sage 실행 단위 취소 상태
# ============================================================
# 취소 상태와 작업 파일은 현재 실행의 .tmp 아래에 유지한다.
#
# cancelled       : Ctrl+C/TERM 요청 marker.
#                   신규 JID 제출 및 후속 처리 차단 기준
# cancel.log      : 취소 처리 이력
# jid_registering : JID 발급 직후 registry 기록이 끝날 때까지의 보호 marker
# cancel_work/    : JID별 취소 상태 확인 및 term/kill 작업 파일
#
# 일반 실행 및 취소 종료 시 .tmp는 start.sh cleanup에서 삭제한다.
# ASYNC_RESULT=true로 정상 handoff된 경우에는 listener가
# 전체 결과 수신 및 post 처리 완료 후 .tmp를 삭제한다.
#
# CANCEL_* 값은 취소 확인용 Salt CLI의 응답/하드 timeout과
# TERM -> KILL 전환 대기 시간을 제한한다.
# ============================================================
SAGE_CANCEL_MARKER="$tmp_dir/cancelled"
SAGE_CANCEL_LOG="$tmp_dir/cancel.log"
SAGE_JID_PROTECT_MARKER="$tmp_dir/jid_registering"

CANCEL_REQUESTED=0
CANCEL_IN_PROGRESS=0
CANCEL_SIGNAL=""
CANCEL_KEEP_FILE_DEPLOY_STAGE=0
CANCEL_SALT_TIMEOUT="${CANCEL_SALT_TIMEOUT:-2}"
CANCEL_COMMAND_HARD_TIMEOUT="${CANCEL_COMMAND_HARD_TIMEOUT:-8}"
CANCEL_TERM_WAIT="${CANCEL_TERM_WAIT:-2}"
CANCEL_KILL_WAIT="${CANCEL_KILL_WAIT:-1}"
CANCEL_TARGET_CHUNK_SIZE="${CANCEL_TARGET_CHUNK_SIZE:-200}"
SAGE_ACTIVE_WAIT_PID=""
SAGE_ROOT_BASHPID="$BASHPID"

export SAGE_ROOT_BASHPID
export SAGE_CANCEL_MARKER
export SAGE_CANCEL_LOG
export SAGE_JID_PROTECT_MARKER

# ============================================================
# Sage 취소 로그
# ============================================================
sage_cancel_log() {
    mkdir -p "$tmp_dir" 

    printf '%s\t%s\n' \
        "$(date '+%F %T')" \
        "$*" \
        >> "$SAGE_CANCEL_LOG"
}

# 진행률 출력이 \r로 같은 줄을 갱신 중이어도 취소 안내가 보이도록
# 가능하면 제어 터미널(/dev/tty)에 직접 출력하고, 실패하면 stderr로 보낸다.
sage_cancel_notice() {
    local message="$1"

    if { printf '%s\n' "$message" > /dev/tty; } 2>/dev/null; then
        return 0
    fi

    printf '%s\n' "$message" >&2
}
# ============================================================
# saltutil.find_job JSON에서 상태 판정 가능한 minion key 추출
#
# mode:
#   responded : value가 object인 정상 응답 minion
#   active    : value가 비어 있지 않은 object인 실행 중 minion
# ============================================================
sage_cancel_json_keys() {
    local json_file="$1"
    local mode="$2"

    python3 - "$json_file" "$mode" <<'PY'
import json
import sys

path = sys.argv[1]
mode = sys.argv[2]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)

for host, value in data.items():
    # saltutil.find_job의 정상 응답은 dict다.
    # {}        = 해당 JID가 현재 실행 중이 아님
    # non-empty = 현재 실행 중
    #
    # timeout/error 문자열 등은 정상 find_job 응답으로 보지 않는다.
    if mode == "responded":
        if isinstance(value, dict):
            print(host)

    elif mode == "active":
        if isinstance(value, dict) and len(value) > 0:
            print(host)
PY
}

# ============================================================
# CSV target -> 정렬된 host 파일
# ============================================================
sage_cancel_targets_to_file() {
    local targets="$1"
    local output_file="$2"

    printf '%s\n' "$targets" \
        | tr ',' '\n' \
        | sed '/^[[:space:]]*$/d' \
        | sort -u \
        > "$output_file"
}


# ============================================================
# host 파일을 CANCEL_TARGET_CHUNK_SIZE 단위로 분리
# ============================================================
sage_cancel_make_chunks() {
    local target_file="$1"
    local chunk_dir="$2"

    rm -rf "$chunk_dir"
    mkdir -p "$chunk_dir"

    split \
        -d \
        -a 5 \
        -l "$CANCEL_TARGET_CHUNK_SIZE" \
        "$target_file" \
        "$chunk_dir/chunk_"
}


# ============================================================
# 특정 JID 상태 조회
#
# saltutil.find_job만 사용해 현재 실행 상태를 확인한다.
# 생성 파일:
#   expected  : 조회 대상
#   responded : find_job이 정상 object로 응답한 대상
#   active    : find_job 결과가 비어 있지 않은 실행 중 대상
#   inactive  : find_job이 {}로 응답한 종료/미실행 대상
#   unknown   : timeout/error 등으로 정상 응답을 확인하지 못한 대상
# ============================================================
sage_cancel_find_state() {
    local jid="$1"
    local targets="$2"
    local state_dir="$3"

    local salt_bin="${SALT_BIN:-$(command -v salt 2>/dev/null)}"
    local target_file="$state_dir/expected"
    local chunk_dir="$state_dir/chunks"
    local responded_file="$state_dir/responded"
    local active_file="$state_dir/active"
    local inactive_file="$state_dir/inactive"
    local unknown_file="$state_dir/unknown"
    local chunk_file
    local chunk_targets
    local find_json
    local find_err
    local command_rc

    rm -rf "$state_dir"
    mkdir -p "$state_dir"

    sage_cancel_targets_to_file "$targets" "$target_file"

    : > "$responded_file"
    : > "$active_file"
    : > "$inactive_file"
    : > "$unknown_file"

    sage_cancel_make_chunks "$target_file" "$chunk_dir"

    for chunk_file in "$chunk_dir"/chunk_*; do
        [[ -f "$chunk_file" ]] || continue
        [[ -s "$chunk_file" ]] || continue

        chunk_targets="$(paste -sd, "$chunk_file")"

        find_json="${chunk_file}.find.json"
        find_err="${chunk_file}.find.err"

        timeout \
            --signal=TERM \
            --kill-after=2 \
            "${CANCEL_COMMAND_HARD_TIMEOUT}s" \
            "$salt_bin" \
            -t "$CANCEL_SALT_TIMEOUT" \
            --out=json \
            --static \
            -L "$chunk_targets" \
            saltutil.find_job "$jid" \
            > "$find_json" \
            2> "$find_err"

        command_rc=$?

        if sage_cancel_json_keys "$find_json" responded \
            >> "$responded_file" 2>/dev/null
        then
            sage_cancel_json_keys "$find_json" active \
                >> "$active_file" 2>/dev/null || true
        else
            sage_cancel_log \
                "find_job_parse_failed jid=$jid targets=$chunk_targets rc=$command_rc"
        fi

        if [[ "$command_rc" -ne 0 ]]; then
            sage_cancel_log \
                "find_job_command_rc jid=$jid targets=$chunk_targets rc=$command_rc"
        fi
    done

    sort -u -o "$responded_file" "$responded_file"
    sort -u -o "$active_file" "$active_file"

    # 정상 find_job 응답은 했지만 현재 해당 JID가 실행 중이 아닌 대상
    comm -23 \
        "$responded_file" \
        "$active_file" \
        > "$inactive_file"

    # 정상 find_job 응답 자체를 확인하지 못한 대상
    comm -23 \
        "$target_file" \
        "$responded_file" \
        > "$unknown_file"

    return 0
}


# ============================================================
# host 파일의 대상에게 term_job / kill_job 실행
# ============================================================
sage_cancel_signal_hosts() {
    local jid="$1"
    local host_file="$2"
    local function_name="$3"
    local work_dir="$4"

    local salt_bin="${SALT_BIN:-$(command -v salt 2>/dev/null)}"
    local chunk_dir="$work_dir/${function_name}_chunks"
    local chunk_file
    local chunk_targets
    local output_file
    local error_file
    local command_rc

    [[ -s "$host_file" ]] || return 0

    sage_cancel_make_chunks "$host_file" "$chunk_dir"

    for chunk_file in "$chunk_dir"/chunk_*; do
        [[ -f "$chunk_file" ]] || continue
        [[ -s "$chunk_file" ]] || continue

        chunk_targets="$(paste -sd, "$chunk_file")"

        output_file="${chunk_file}.out"
        error_file="${chunk_file}.err"

        timeout \
            --signal=TERM \
            --kill-after=5 \
            "${CANCEL_COMMAND_HARD_TIMEOUT}s" \
            "$salt_bin" \
            -t "$CANCEL_SALT_TIMEOUT" \
            --out=json \
            --static \
            -L "$chunk_targets" \
            "saltutil.${function_name}" "$jid" \
            > "$output_file" \
            2> "$error_file"

        command_rc=$?

        sage_cancel_log \
            "${function_name} jid=$jid targets=$chunk_targets rc=$command_rc"
    done

    return 0
}


# ============================================================
# 단일 JID 취소
#
# 순서:
#   find_job으로 active 확인
#   -> active 대상 term_job
#   -> 짧게 대기 후 최초 active 대상만 find_job 재확인
#   -> 남은 active 대상 kill_job
#   -> 짧게 대기 후 강제 종료 대상만 최종 확인
#
# 상태를 확인하지 못한 host는 unconfirmed로 남겨 file_deploy staging
# 삭제 여부를 보수적으로 판단한다.
# ============================================================
sage_cancel_one_jid() {
    local context="$1"
    local label="$2"
    local jid="$3"
    local target_count="$4"
    local targets="$5"

    local jid_dir="$tmp_dir/cancel_work/$jid"
	local before_dir="$jid_dir/before"
    local after_term_dir="$jid_dir/after_term"
    local final_dir="$jid_dir/final"
    local unconfirmed_file="$jid_dir/unconfirmed"

    local active_before=0
    local inactive_before=0
    local unknown_before=0

    local active_after_term=0
    local inactive_after_term=0
    local unknown_after_term=0

    local active_final=0
    local inactive_final=0
    local unknown_final=0

    local after_term_targets=""
    local final_targets=""

    sage_cancel_log \
        "jid_cancel_start context=$context label=$label jid=$jid target_count=$target_count"

    # --------------------------------------------------------
    # 최초에는 original targets 전체에서 실제 실행 중 host를 찾는다.
    # --------------------------------------------------------
    sage_cancel_find_state \
        "$jid" \
        "$targets" \
        "$before_dir"

    active_before="$(wc -l < "$before_dir/active")"
    inactive_before="$(wc -l < "$before_dir/inactive")"
    unknown_before="$(wc -l < "$before_dir/unknown")"

    sage_cancel_log \
        "jid_state_before context=$context label=$label jid=$jid active=$active_before inactive=$inactive_before unknown=$unknown_before"

    # --------------------------------------------------------
    # 현재 실행 중으로 확인된 host에만 SIGTERM
    # --------------------------------------------------------
    if [[ "$active_before" -gt 0 ]]; then
        sage_cancel_signal_hosts \
            "$jid" \
            "$before_dir/active" \
            "term_job" \
            "$jid_dir"

        sleep "$CANCEL_TERM_WAIT"
    fi

    # --------------------------------------------------------
    # TERM 이후에는 최초 active였던 host만 다시 확인
    # --------------------------------------------------------
    after_term_targets="$(paste -sd, "$before_dir/active" 2>/dev/null || true)"

    sage_cancel_find_state \
        "$jid" \
        "$after_term_targets" \
        "$after_term_dir"

    active_after_term="$(wc -l < "$after_term_dir/active")"
    inactive_after_term="$(wc -l < "$after_term_dir/inactive")"
    unknown_after_term="$(wc -l < "$after_term_dir/unknown")"

    sage_cancel_log \
        "jid_state_after_term context=$context label=$label jid=$jid active=$active_after_term inactive=$inactive_after_term unknown=$unknown_after_term"

    # --------------------------------------------------------
    # SIGTERM 이후에도 실행 중인 host에만 SIGKILL
    # --------------------------------------------------------
    if [[ "$active_after_term" -gt 0 ]]; then
        sage_cancel_signal_hosts \
            "$jid" \
            "$after_term_dir/active" \
            "kill_job" \
            "$jid_dir"

        sleep "$CANCEL_KILL_WAIT"
    fi

    # --------------------------------------------------------
    # KILL 이후에도 방금 active였던 host만 최종 확인
    # --------------------------------------------------------
    final_targets="$(paste -sd, "$after_term_dir/active" 2>/dev/null || true)"

    sage_cancel_find_state \
        "$jid" \
        "$final_targets" \
        "$final_dir"

    active_final="$(wc -l < "$final_dir/active")"
    inactive_final="$(wc -l < "$final_dir/inactive")"
    unknown_final="$(wc -l < "$final_dir/unknown")"

    # 최초부터 상태 확인이 안 됐거나,
    # TERM/KILL 이후 상태 확인이 안 된 host는 종료 미확인으로 남긴다.
    {
        cat "$before_dir/unknown"
        cat "$after_term_dir/unknown"
        cat "$final_dir/active"
        cat "$final_dir/unknown"
    } 2>/dev/null |
        sed '/^[[:space:]]*$/d' |
        sort -u \
        > "$unconfirmed_file"

    sage_cancel_log \
        "jid_cancel_end context=$context label=$label jid=$jid active=$active_final inactive=$inactive_final unknown=$unknown_final unconfirmed=$(wc -l < "$unconfirmed_file")"

    # file_deploy는 하나라도 종료 상태가 명확하지 않으면 staging 유지
    if [[ "$context" == "file_deploy" ]] &&
        [[ -s "$unconfirmed_file" ]]
    then
        CANCEL_KEEP_FILE_DEPLOY_STAGE=1

        sage_cancel_log \
            "file_deploy_stage_keep jid=$jid unconfirmed=$(wc -l < "$unconfirmed_file")"
    fi

    # 최초에 실제 RUNNING이었고, 취소 후 종료 상태가 모두 확인된 경우에만
    # CANCELLED history를 남긴다.
    if (( active_before > 0 )) && [[ ! -s "$unconfirmed_file" ]]; then
        if [[ "${CANCEL_SIGNAL:-INT}" == "TERM" ]]; then
            append_sage_jid_history \
                "$jid" "$context" "$label" "$target_count" "143"
        else
            append_sage_jid_history \
                "$jid" "$context" "$label" "$target_count" "130"
        fi
    fi

    return 0
}

# ============================================================
# 취소 시 현재 shell이 기다리는 로컬 Salt CLI process group 종료
# ============================================================
sage_cancel_stop_local_process_group() {
    local pid="${1:-}"
    local label="${2:-unknown}"

    [[ "$pid" =~ ^[0-9]+$ ]] || return 0

    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    sage_cancel_log \
        "local_process_stop label=$label pid=$pid signal=TERM"

    kill -TERM -- "-$pid" 2>/dev/null || true

    sleep 0.2

    if kill -0 "$pid" 2>/dev/null; then
        sage_cancel_log \
            "local_process_stop label=$label pid=$pid signal=KILL"

        kill -KILL -- "-$pid" 2>/dev/null || true
    fi

    return 0
}

# ============================================================
# 현재 Sage run 전체 취소
#
# 1) 현재 shell이 기다리는 조회/stream Salt CLI를 먼저 정리
# 2) jid_registry를 snapshot한 뒤 최신 JID부터 역순 처리
# 3) 각 JID는 term_job -> 필요 시 kill_job으로 종료
# ============================================================
run_sage_cancel_engine() {
    local registry_snapshot="$tmp_dir/jid_registry.snapshot"
	local registry_lock="${JID_REGISTRY_LOCK_FILE:-}"
    local context
    local label
    local jid
    local target_count
    local targets

    if [[ "${CANCEL_IN_PROGRESS:-0}" -eq 1 ]]; then
        return 0
    fi

    CANCEL_IN_PROGRESS=1

    # 취소 엔진이 시작된 뒤 추가 Ctrl+C/TERM은 중복 처리하지 않는다.
    trap '' INT TERM

    set +e

    mkdir -p "$tmp_dir" 

    # 로컬 Salt CLI는 대기 해제용으로 먼저 종료한다.
    # 실제 minion job은 아래 jid_registry 기반 term_job/kill_job으로 처리한다.
    sage_cancel_stop_local_process_group \
        "${SAGE_ACTIVE_WAIT_PID:-}" \
        "salt_wait"
    SAGE_ACTIVE_WAIT_PID=""

    sage_cancel_stop_local_process_group \
        "${SAGE_ACTIVE_SALT_PID:-}" \
        "salt_stream"
    SAGE_ACTIVE_SALT_PID=""

    sage_cancel_log \
        "cancel_engine_start run_id=$SAGE_RUN_ID signal=${CANCEL_SIGNAL:-unknown}"

    : > "$registry_snapshot"

    # registry append와 snapshot이 겹치지 않도록 동일 lock 사용
    if [[ -n "$registry_lock" ]]; then
        (
            flock -x 200

            if [[ -s "$JID_REGISTRY_FILE" ]]; then
                awk -F $'\t' \
                    -v run_id="$SAGE_RUN_ID" \
                    '$1 == run_id' \
                    "$JID_REGISTRY_FILE" \
                    | tac \
                    > "$registry_snapshot"
            fi
        ) 200>"$registry_lock"
    elif [[ -s "$JID_REGISTRY_FILE" ]]; then
        awk -F $'\t' \
            -v run_id="$SAGE_RUN_ID" \
            '$1 == run_id' \
            "$JID_REGISTRY_FILE" \
            | tac \
            > "$registry_snapshot"
    fi

    if [[ ! -s "$registry_snapshot" ]]; then
        sage_cancel_log \
            "cancel_engine_no_registered_jid run_id=$SAGE_RUN_ID"
    else
        while IFS=$'\t' read -r \
            _run_id \
            context \
            label \
            jid \
            target_count \
            targets
        do
            [[ "$jid" =~ ^[0-9]+$ ]] || continue
            [[ -n "$targets" ]] || continue

            sage_cancel_one_jid \
                "$context" \
                "$label" \
                "$jid" \
                "$target_count" \
                "$targets"
        done < "$registry_snapshot"
    fi

    sage_cancel_log \
        "cancel_engine_end run_id=$SAGE_RUN_ID keep_file_deploy_stage=$CANCEL_KEEP_FILE_DEPLOY_STAGE"

    if [[ "${CANCEL_SIGNAL:-INT}" == "TERM" ]]; then
        exit 143
    fi

    exit 130
}
# ============================================================
# Sage 취소 요청 처리
# ============================================================
# 최초 신호에서 cancelled marker/log를 만든다.
# JID가 registry에 기록 중이면 보호구간 종료까지 연기하고,
# 그 외에는 즉시 run_sage_cancel_engine을 실행한다.
# ============================================================
handle_cancel() {
    local signal_name="${1:-INT}"

    # 실제 취소 엔진이 이미 실행 중이면
    # 추가 Ctrl+C/TERM은 무시한다.
    if [[ "${CANCEL_IN_PROGRESS:-0}" -eq 1 ]]; then
        return 0
    fi

    # 최초 취소 요청일 때만 marker/log 생성
    if [[ "${CANCEL_REQUESTED:-0}" -ne 1 ]]; then
        CANCEL_REQUESTED=1
        CANCEL_SIGNAL="$signal_name"

       	mkdir -p "$tmp_dir" 

        printf '%s\trun_id=%s\tsignal=%s\n' \
            "$(date '+%F %T')" \
            "$SAGE_RUN_ID" \
            "$signal_name" \
            > "$SAGE_CANCEL_MARKER"

        sage_cancel_log \
            "cancel_requested run_id=$SAGE_RUN_ID signal=$signal_name"

        sage_cancel_notice $'\n  Sage 작업 취소 요청을 받았습니다.'
    fi

    # Salt JID 발급 -> registry 기록 보호구간이면
    # JID 등록을 완료한 뒤 취소 엔진을 실행한다.
    if [[ -e "${SAGE_JID_PROTECT_MARKER:-}" ]]; then
        sage_cancel_log \
            "cancel_deferred run_id=$SAGE_RUN_ID reason=jid_registering"

        sage_cancel_notice '  JID 등록을 완료한 후 작업을 중지합니다.'

        return 0
    fi

    run_sage_cancel_engine
}

cleanup() {
	# ============================================================
	# Salt fileserver에 임시로 노출한 file_deploy source 정리
	#
	# 정상 종료:
	#   staging 삭제
	#
	# 취소 종료:
	#   모든 file_deploy JID가 inactive로 확인됐으면 삭제
	#   active 또는 상태 미확인(unknown)이 남아 있으면 유지
	# ============================================================
	if [[ -n "${file_deploy_stage_root:-}" ]]; then
	    if [[ "${CANCEL_KEEP_FILE_DEPLOY_STAGE:-0}" -eq 1 ]]; then
	        echo
	        echo "  file_deploy staging을 유지합니다."
	        echo "  경로: $file_deploy_stage_root"
	
	        if [[ -n "${SAGE_CANCEL_LOG:-}" ]]; then
	            printf '%s\tfile_deploy_stage_preserved\trun_id=%s\tpath=%s\n' \
	                "$(date '+%F %T')" \
	                "${SAGE_RUN_ID:-unknown}" \
	                "$file_deploy_stage_root" \
	                >> "$SAGE_CANCEL_LOG"
	        fi
	    else
	        rm -rf "$file_deploy_stage_root"
	        rmdir "$apply_dir/sage_file_deploy" 2>/dev/null || true
	
	        if [[ "${CANCEL_REQUESTED:-0}" -eq 1 ]] &&
	            [[ -n "${SAGE_CANCEL_LOG:-}" ]]
	        then
	            printf '%s\tfile_deploy_stage_removed\trun_id=%s\tpath=%s\n' \
	                "$(date '+%F %T')" \
	                "${SAGE_RUN_ID:-unknown}" \
	                "$file_deploy_stage_root" \
	                >> "$SAGE_CANCEL_LOG"
	        fi
	    fi
	fi

    if [[ "${LOCK_ACQUIRED:-0}" -eq 1 && -n "${lock_file:-}" ]]; then
        rm -f "$lock_file"
    fi

	if [[ "${CANCEL_REQUESTED:-0}" -eq 1 ||
		  -s "${SAGE_CANCEL_MARKER:-$tmp_dir/cancelled}" ]]
	then
	    rm -rf "$tmp_dir"

	elif [[ "${ASYNC_RESULT_HANDOFF:-0}" -eq 1 ]]; then
	    if [[ "$KEEP_TMP" -eq 1 ]]; then
	        echo "[DEBUG] tmp 유지: $tmp_dir"
	    else
	        find "$tmp_dir" \
	            -mindepth 1 -maxdepth 1 \
	            ! -name 'async_pending' \
	            ! -name 'result_status' \
	            -exec rm -rf -- {} +

			rmdir "$tmp_dir" 2>/dev/null || true

	    fi
	
	elif [[ "$KEEP_TMP" -eq 1 ]]; then
	    echo "[DEBUG] tmp 유지: $tmp_dir"
	
	else
	    rm -rf "$tmp_dir"
	fi
}

trap 'handle_cancel INT' INT
trap 'handle_cancel TERM' TERM
trap cleanup EXIT

# ============================================================
# SLS 파일 경로 찾기
# 예:
#   sample       -> $apply_dir/sample/init.sls
#   a.b.c        -> $apply_dir/a/b/c/init.sls
# ============================================================
find_sls_file() {
    local sls_name="$1"
    local sls_path="${sls_name//./\/}"

    if [[ -f "$apply_dir/$sls_path/init.sls" ]]; then
        echo "$apply_dir/$sls_path/init.sls"
        return 0
    fi

    return 1
}

# ============================================================
# salt:// 경로를 실제 Master 파일 경로로 변환
# 예:
#   salt://sample/test.sh
#   -> $apply_dir/sample/test.sh
# ============================================================
salt_source_to_file() {
    local source="$1"

    source="${source#salt://}"
    echo "$apply_dir/$source"
}

# ============================================================
# SLS 안에 선언된 salt:// source 파일 검증
# - source 파일이 없으면 실패
# - source 파일이 비어있으면 실패
# ============================================================
validate_salt_sources_in_sls() {
    local sls_file="$1"
    local missing=0
    local source
    local src_file

    while IFS= read -r source; do
        [[ -z "$source" ]] && continue

        src_file="$(salt_source_to_file "$source")"

        if [[ ! -f "$src_file" ]]; then
            echo "source 파일 없음: $src_file"
            missing=1
        elif [[ ! -s "$src_file" ]]; then
            echo "source 파일이 비어있습니다: $src_file"
            missing=1
        fi
    done < <(
        grep -E '^[[:space:]]*-[[:space:]]*source:[[:space:]]*salt://' "$sls_file" \
            | sed -E 's/^[[:space:]]*-[[:space:]]*source:[[:space:]]*//'
    )

    if [[ "$missing" -ne 0 ]]; then
        exit 1
    fi
}

# ============================================================
# 실행 전 작업 검증
# 지원 SALT_FUNCTION:
#   - state.apply
#   - cmd.run
#   - state.single
# ============================================================
validate_job() {
    case "$SALT_FUNCTION" in
        state.apply)
            local sls_name="${SALT_ARGS[0]:-}"
            local sls_file=""

            if [[ -z "$sls_name" ]]; then
                echo "state.apply 대상 SLS 이름이 없습니다."
                exit 1
            fi

            # state.apply 대상 SLS 파일 존재 여부 확인
            if ! sls_file="$(find_sls_file "$sls_name")"; then
                echo "SLS 파일 없음: $apply_dir/${sls_name//./\/}/init.sls"
                exit 1
            fi

            if [[ ! -s "$sls_file" ]]; then
                echo "SLS 파일이 비어있습니다: $sls_file"
                exit 1
            fi

            # SLS 내부 salt:// source 파일 사전 검증
            validate_salt_sources_in_sls "$sls_file"
            ;;

        cmd.run)
            if (( ${#SALT_ARGS[@]} == 0 )); then
                echo "cmd.run 실행 인자가 없습니다."
                exit 1
            fi

            # __RUN_SCRIPT__ 모드는 RUN_SCRIPT 파일을 대상 서버에서 실행
            if [[ "${SALT_ARGS[0]:-}" == "__RUN_SCRIPT__" ]]; then
                if [[ -z "${RUN_SCRIPT:-}" ]]; then
                    echo "RUN_SCRIPT 변수가 없습니다."
                    exit 1
                fi

                if [[ ! -f "$RUN_SCRIPT" ]]; then
                    echo "RUN_SCRIPT 파일 없음: $RUN_SCRIPT"
                    exit 1
                fi

                if [[ ! -s "$RUN_SCRIPT" ]]; then
                    echo "RUN_SCRIPT 파일이 비어있습니다: $RUN_SCRIPT"
                    exit 1
                fi
            fi
            ;;

        state.single)
            local state_mod="${SALT_ARGS[0]:-}"
            local src=""
            local dst=""
            local src_file=""
            local arg=""

            if [[ -z "$state_mod" ]]; then
                echo "state.single 실행 모듈이 없습니다."
                exit 1
            fi

            # state.single file.managed 전용 검증
            if [[ "$state_mod" == "file.managed" ]]; then
                for arg in "${SALT_ARGS[@]}"; do
                    case "$arg" in
                        name=*)
                            dst="${arg#name=}"
                            ;;
                        source=*)
                            src="${arg#source=}"
                            ;;
                    esac
                done

                if [[ -z "$dst" ]]; then
                    echo "state.single file.managed에 name= 값이 없습니다."
                    exit 1
                fi

                if [[ -z "$src" ]]; then
                    echo "state.single file.managed에 source= 값이 없습니다."
                    exit 1
                fi

                if [[ "$src" != salt://* ]]; then
                    echo "현재 source 검증은 salt:// 경로만 지원합니다: $src"
                    exit 1
                fi

                # salt:// source를 실제 master 파일 경로로 변환
                src_file="$(salt_source_to_file "$src")"

                if [[ ! -f "$src_file" ]]; then
                    echo "source 파일 없음: $src_file"
                    exit 1
                fi

                if [[ ! -s "$src_file" ]]; then
                    echo "source 파일이 비어있습니다: $src_file"
                    exit 1
                fi
            fi
            ;;

        *)
            echo "지원하지 않는 SALT_FUNCTION입니다: $SALT_FUNCTION"
            exit 1
            ;;
    esac
}

run_post() {
    log_dir="${log_dir:-$base_dir/log}"
    log="$log_dir/log_salt"
    server_file="$base_dir/server"
    result_dir="$base_dir/result"
    error_dir="$base_dir/error"
    result_status="${RESULT_STATUS_FILE:-${tmp_dir:-$base_dir/.tmp}/result_status}"

	# start.sh 시작 단계에서 이미 이전 실행 결과를 초기화한다.
	# local의 file_deploy가 먼저 만든 error/<host>를 유지해야 하므로
	# 여기서는 result/error를 다시 삭제하지 않고 디렉토리만 보장한다.
	mkdir -p "$result_dir" "$error_dir"

    # ============================================================
    # log_salt JSON 파싱
    # ============================================================
    # Salt 출력은 상황에 따라 여러 JSON 객체가 연속으로 쌓일 수 있음.
    # JSONDecoder.raw_decode()로 파일 안의 JSON 객체를 순차적으로 찾아서 파싱한다.
    #
	# 결과 저장 정책:
	#   result/<host>
	#     - 정상 결과의 stdout 저장
	#     - 정상 결과에 stdout이 없으면 빈 파일 생성
	#
	#   error/<host>
	#     - stderr가 있으면 stderr 저장
	#     - cmd.run 실패 시 stderr 없이 stdout만 있으면 stdout 저장
	#     - cmd.run 실패 시 stderr/stdout이 모두 없으면 빈 error 파일 생성
	#     - state 실패 시 stderr가 없으면 실패 comment 저장
	#     - state 실패 시 stderr/comment가 모두 없으면 no_stderr 저장
	#
	#   성공 상태의 comment는 저장하지 않는다.
	# ============================================================
    python3 - "$log" "$server_file" "$result_dir" "$error_dir" <<'PY'
import json
import os
import sys

log_path = sys.argv[1]
server_file = sys.argv[2]
result_dir = sys.argv[3]
error_dir = sys.argv[4]

try:
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        data = f.read()
except FileNotFoundError:
    data = ""

# 최종 실행 대상 host 목록
try:
    with open(server_file, "r", encoding="utf-8", errors="replace") as f:
        target_hosts = [
            line.strip().split()[0]
            for line in f
            if line.strip() and not line.lstrip().startswith("#")
        ]
except FileNotFoundError:
    target_hosts = []

target_set = set(target_hosts)
returned_hosts = set()
parsed_count = 0

def write_file(directory, host, content):
    path = os.path.join(directory, host)

    if content is None:
        content = ""

    content = str(content).rstrip()

    # file_deploy가 local 단계에서 먼저 만든 error/<host>가 있으면
    # remote 오류를 덮어쓰지 않고 빈 줄 뒤에 추가한다.
    append_mode = directory == error_dir and os.path.exists(path)
    mode = "a" if append_mode else "w"

    with open(path, mode, encoding="utf-8") as out:
        if append_mode and os.path.getsize(path) > 0 and content:
            out.write("\n")

        if content:
            out.write(content + "\n")
        elif not append_mode:
            out.write("")

def stringify_value(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float, bool)):
        return str(value)
    if isinstance(value, list):
        return "\n".join(str(x) for x in value)
    if isinstance(value, dict):
        return json.dumps(value, ensure_ascii=False, indent=4, sort_keys=True)
    return str(value)


def parse_cmd_dict(value):
    """cmd.run_all 결과(dict)를 stdout/stderr/retcode 기준으로 result/error 분리한다."""
    stdout = value.get("stdout")
    stderr = value.get("stderr")
    retcode = value.get("retcode")

    stdout = "" if stdout is None else str(stdout).rstrip()
    stderr = "" if stderr is None else str(stderr).rstrip()

    if stderr:
        return stdout, stderr

    if retcode not in (None, 0, "0"):
        if stdout:
            return "", stdout
        return "", "no_stderr"

    return stdout, ""

def parse_state_result(states):
    """state.apply/state.single 결과를 stdout/stderr/comment 기준으로 정상/에러 분리한다."""
    stdout_list = []
    stderr_list = []
    error_comment_list = []
    has_error = False

    for state_id, state_data in states.items():
        if not isinstance(state_data, dict):
            continue

        changes = state_data.get("changes", {})

        if isinstance(changes, dict):
            stdout = changes.get("stdout")
            stderr = changes.get("stderr")
            retcode = changes.get("retcode")

            if stdout:
                stdout_list.append(str(stdout).rstrip())

            if stderr:
                stderr_list.append(str(stderr).rstrip())

            if retcode not in (None, 0, "0"):
                has_error = True

        result = state_data.get("result")
        comment = state_data.get("comment")

        if result is False:
            has_error = True

            # 실패 상태의 comment만 에러 원인으로 저장한다.
            # 성공 comment는 result/error에 저장하지 않는다.
            if comment:
                error_comment_list.append(str(comment).rstrip())

    # 실패가 있거나 stderr가 있으면 error/<host> 로 저장한다.
    # 우선순위:
    #   1. stderr
    #   2. 실패 comment
    #   3. no_stderr
    if has_error or stderr_list:
        if stderr_list:
            return False, "\n".join(x for x in stderr_list if x)

        if error_comment_list:
            return False, "\n".join(x for x in error_comment_list if x)

        return False, "no_stderr"

    # 정상 결과는 stdout만 저장한다.
    # stdout이 없으면 빈 파일로 생성한다.
    if stdout_list:
        return True, "\n".join(x for x in stdout_list if x)

    return True, ""


def handle_host_result(host, value):
    returned_hosts.add(host)

    # cmd.run --out=json 기본 형태: {"host": "stdout"}
    if isinstance(value, str):
        write_file(result_dir, host, value)
        return

    # 숫자/불리언/null 방어
    if value is None or isinstance(value, (int, float, bool)):
        write_file(result_dir, host, stringify_value(value))
        return

    # list 방어
    if isinstance(value, list):
        write_file(result_dir, host, stringify_value(value))
        return

    if isinstance(value, dict):
        # cmd.run dict 형태
        if any(key in value for key in ("stdout", "stderr", "retcode")):
            result_content, error_content = parse_cmd_dict(value)

            if result_content or value.get("retcode") in (None, 0, "0"):
                write_file(result_dir, host, result_content)

            if error_content:
                if error_content == "no_stderr":
                    write_file(error_dir, host, "")
                else:
                    write_file(error_dir, host, error_content)

            return

        # state.apply/state.single 형태로 간주
        ok, content = parse_state_result(value)
        if ok:
            write_file(result_dir, host, content)
        else:
            write_file(error_dir, host, content)
        return

    write_file(result_dir, host, stringify_value(value))

decoder = json.JSONDecoder()
idx = 0

while idx < len(data):
    start = data.find("{", idx)

    if start == -1:
        break

    try:
        obj, end = decoder.raw_decode(data[start:])
    except json.JSONDecodeError:
        idx = start + 1
        continue

    parsed_count += 1

    if isinstance(obj, dict):
        for host, value in obj.items():
            # Salt 메타 필드 제외
            if host in ("retcode", "jid"):
                continue

            # server_file에 있는 host만 처리한다.
            # target_set이 비어 있으면 방어적으로 모든 host key를 처리한다.
            if target_set and host not in target_set:
                continue

            handle_host_result(host, value)

    idx = start + end

# 파싱 결과를 후속 bash 단계에서 사용할 수 있게 returned host 목록 저장
returned_path = os.path.join(os.path.dirname(result_dir), ".tmp", "post_returned_hosts")
os.makedirs(os.path.dirname(returned_path), exist_ok=True)

with open(returned_path, "w", encoding="utf-8") as out:
    for host in sorted(returned_hosts):
        out.write(host + "\n")

# JSON 객체를 하나도 파싱하지 못해도 여기서 바로 실패시키지는 않는다.
# result_status/no_return 처리는 bash 쪽에서 이어서 수행한다.
PY

	append_error_content() {
    	local host="$1"
    	local content="$2"
    	local error_file="$error_dir/$host"

    	if [[ -s "$error_file" && -n "$content" ]]; then
        	echo >> "$error_file"
    	fi

    	if [[ -n "$content" ]]; then
        	printf '%s\n' "$content" >> "$error_file"
    	elif [[ ! -e "$error_file" ]]; then
        	: > "$error_file"
    	fi
	}
    returned_hosts_file="${tmp_dir:-$base_dir/.tmp}/post_returned_hosts"

    # ============================================================
    # result_status 반영
    # ============================================================
    # result_status는 salt_apply의 중간 상태다.
    # 최종 log_salt에 host return이 있으면 그 결과가 우선이므로 result_status는 무시한다.
    # 최종 결과에도 없는 host만 error/<host> 로 기록한다.
    # ============================================================
    if [[ -s "$result_status" ]]; then
        while IFS=$'\t' read -r host status rest; do
            [[ -z "${host:-}" ]] && continue
            [[ -z "${status:-}" ]] && continue

            # 최종 log_salt에 return이 있었던 host면 중간 상태를 무시한다.
            if [[ -s "$returned_hosts_file" ]] && grep -Fxq "$host" "$returned_hosts_file"; then
                continue
            fi

			# 최종 파싱에서 result가 만들어졌으면 중복 기록하지 않는다.
			# error/<host>는 file_deploy가 먼저 만들었을 수 있으므로
			# 존재 여부만으로 건너뛰지 않고 remote 상태를 뒤에 추가한다.
			if [[ -f "$result_dir/$host" ]]; then
				continue
			fi

			append_error_content "$host" "$status"
		done < "$result_status"
    fi

    # ============================================================
    # no_return 처리
    # ============================================================
    # 최종 실행 대상 server_file 기준으로 result/error 어디에도 없는 서버는
    # Salt 결과가 돌아오지 않은 것으로 보고 error/no_return 으로 저장한다.
    # ============================================================
    while IFS= read -r host; do
        [[ -z "$host" ]] && continue
        [[ "$host" =~ ^# ]] && continue

        host="${host%%[[:space:]]*}"

		# 최종 Salt return이 있으면 result/error 파싱 결과가 우선이다.
		if [[ -s "$returned_hosts_file" ]] && grep -Fxq "$host" "$returned_hosts_file"; then
		    continue
		fi

		# result_status에 이미 분류된 host면 해당 상태를 사용한다.
		if [[ -s "$result_status" ]] && awk -F '\t' -v target="$host" '$1 == target {found=1} END {exit !found}' "$result_status"; then
		    continue
		fi

		# file_deploy error가 이미 있어도 remote no_return은 뒤에 추가한다.
		if [[ ! -f "$result_dir/$host" ]]; then
		    append_error_content "$host" "no_return"
		fi
	done < "$server_file"

	RESULT_FILE_COUNT="$(find "$result_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)"
	ERROR_FILE_COUNT="$(find "$error_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)"
}
# ============================================================
# 사용자 post 스크립트 사용 여부 확인
# ============================================================
# $base_dir/post 파일이 존재하고, 주석/공백이 아닌 실제 명령이 있으면 true.
# 주석과 공백만 있거나 파일이 없으면 false.
# ============================================================
post_has_effective_content() {
    local post_file="${1:-$base_dir/post}"

    [[ -f "$post_file" ]] || return 1

    grep -Eq '^[[:space:]]*[^#[:space:]]' "$post_file"
}

# ============================================================
# 사용자 post 스크립트 실행
# ============================================================
# run_post()가 result/ error/ 생성을 완료한 뒤 마지막으로 실행한다.
# post 파일은 사용자 정의 후처리 전용이며, 형식은 자유다.
# ============================================================

run_user_post() {
    local post_file="$base_dir/post"
    local user_post_rc=0

    if ! post_has_effective_content "$post_file"; then
        return 0
    fi

    sage_print_section "post 실행"

    set +e
    (
        # post 내부의 상대경로와 pwd는 항상 현재 job 디렉토리를 기준으로 한다.
        cd "$base_dir"
        . "$post_file"
    )
    user_post_rc=$?
    set -e

    if [[ "$user_post_rc" -ne 0 ]]; then
        printf '  post 스크립트 실행 실패 (rc=%s)\n' "$user_post_rc"
    else
        echo "  post 스크립트 실행 완료"
    fi
}

# ============================================================
# local 스크립트 사용 여부 확인
# ============================================================
# $base_dir/local 파일이 있고, 주석/공백이 아닌 실제 명령이 있으면 사용한다.
# local은 Salt 실행 전에 master 로컬에서 실행되는 선택 스크립트다.
# ============================================================
has_user_local() {
    local local_file="$base_dir/local"

    [[ -f "$local_file" ]] || return 1

    grep -qEv '^[[:space:]]*($|#)' "$local_file"
}

# ============================================================
# file_deploy 내부 함수
# ============================================================
# local 안에서 아래 형식으로 사용한다.
#
#   file_deploy "$base_dir/files/app.tar.gz" "/home/"
#
# 동작:
#   - 호출 위치에서 즉시 동기 실행한다.
#   - 목적지가 / 로 끝나면 원본 파일명을 유지한다.
#   - source를 Salt fileserver staging 경로에 hard link 또는 cp -p로 준비한다.
#   - 파일 크기에 따라 JID 청크 크기를 자동 결정한다.
#   - state.single file.managed로 전체 server에 배포한다.
#   - 동일한 파일은 file.managed가 변경 없이 성공 처리한다.
#   - 실패 host는 $base_dir/error/<host>에 deploy fail 내용을 append한다.
#   - 배포 실패 여부와 관계없이 기존 server 목록은 변경하지 않는다.
# ============================================================
file_deploy_call_no=0

__sage_file_deploy_chunk_size() {
    local file_size="$1"

    if (( file_size <= 1 * 1024 * 1024 )); then
        echo 200
    elif (( file_size <= 10 * 1024 * 1024 )); then
        echo 100
    elif (( file_size <= 100 * 1024 * 1024 )); then
        echo 30
    elif (( file_size <= 500 * 1024 * 1024 )); then
        echo 10
    elif (( file_size <= 1024 * 1024 * 1024 )); then
        echo 5
    elif (( file_size <= 5 * 1024 * 1024 * 1024 )); then
        echo 2
    else
        echo 1
    fi
}

__sage_file_deploy_append_error() {
    local host="$1"
    local source_name="$2"
    local error_file="$error_dir/$host"

    mkdir -p "$error_dir"

    if [[ -s "$error_file" ]]; then
        echo >> "$error_file"
    fi

    printf 'deploy fail : %s\n' "$source_name" >> "$error_file"
}

__sage_file_deploy_parse_result() {
    local log_file="$1"
    local server_file="$2"
    local success_file="$3"
    local fail_file="$4"

    python3 - "$log_file" "$server_file" "$success_file" "$fail_file" <<'PY_FILE_DEPLOY_RESULT'
import json
import sys

log_file, server_file, success_file, fail_file = sys.argv[1:]

with open(server_file, "r", encoding="utf-8", errors="replace") as f:
    targets = [
        line.strip().split()[0]
        for line in f
        if line.strip() and not line.lstrip().startswith("#")
    ]

target_set = set(targets)
success = set()

try:
    with open(log_file, "r", encoding="utf-8", errors="replace") as f:
        raw = f.read()
except FileNotFoundError:
    raw = ""


def state_result_is_success(value):
    if not isinstance(value, dict):
        return False

    state_items = [item for item in value.values() if isinstance(item, dict) and "result" in item]

    if not state_items:
        return False

    return all(item.get("result") is True for item in state_items)


decoder = json.JSONDecoder()
idx = 0

while idx < len(raw):
    start = raw.find("{", idx)
    if start == -1:
        break

    try:
        obj, used = decoder.raw_decode(raw[start:])
    except json.JSONDecodeError:
        idx = start + 1
        continue

    if isinstance(obj, dict):
        for host, value in obj.items():
            if host in target_set and state_result_is_success(value):
                success.add(host)

    idx = start + used

with open(success_file, "w", encoding="utf-8") as f:
    for host in targets:
        if host in success:
            f.write(host + "\n")

with open(fail_file, "w", encoding="utf-8") as f:
    for host in targets:
        if host not in success:
            f.write(host + "\n")
PY_FILE_DEPLOY_RESULT
}

file_deploy() {
    local source_input="${1:-}"
    local destination_input="${2:-}"
    local source_file=""
    local source_name=""
    local destination_file=""
    local file_size=0
    local deploy_default_chunk_size=0
    local deploy_chunk_size=0
    local deploy_target_count=0
    local deploy_chunk_count=0
    local deploy_call_label=""
    local deploy_work_dir=""
    local deploy_stage_dir=""
    local deploy_stage_file=""
    local deploy_salt_source=""
    local deploy_server_list=""
    local deploy_salt_run_bin=""
    local deploy_wait_timeout="${FILE_DEPLOY_WAIT_TIMEOUT:-7200}"
    local deploy_salt_rc=0
    local fileserver_cache_rc=0
    local success_file=""
    local fail_file=""
    local success_count=0
    local fail_count=0
    local fail_list=""
    local host=""

    if [[ "${SAGE_LOCAL_ACTIVE:-0}" != "1" ]]; then
        echo "file_deploy는 local 파일 안에서만 사용할 수 있습니다."
        return 1
    fi

    if [[ $# -ne 2 || -z "$source_input" || -z "$destination_input" ]]; then
        echo "file_deploy 사용법:"
        echo '  file_deploy "<원본 파일>" "<대상 경로>"'
        return 1
    fi

    if [[ ! -f "$source_input" ]]; then
        echo "file_deploy 원본 파일 없음: $source_input"
        return 1
    fi

    source_file="$(readlink -f -- "$source_input" 2>/dev/null || true)"

    if [[ -z "$source_file" || ! -f "$source_file" ]]; then
        echo "file_deploy 원본 파일 확인 실패: $source_input"
        return 1
    fi

    if [[ "$destination_input" != /* ]]; then
        echo "file_deploy 대상 경로는 절대경로여야 합니다: $destination_input"
        return 1
    fi

    source_name="$(basename -- "$source_file")"

    if [[ "$destination_input" == */ ]]; then
        destination_file="${destination_input}${source_name}"
    else
        destination_file="$destination_input"
    fi

    if [[ "$destination_file" == "/" ]]; then
        echo "file_deploy 대상 파일 경로가 올바르지 않습니다: $destination_file"
        return 1
    fi

    file_size="$(stat -c '%s' -- "$source_file" 2>/dev/null || true)"

    if [[ ! "$file_size" =~ ^[0-9]+$ ]]; then
        echo "file_deploy 파일 크기 확인 실패: $source_file"
        return 1
    fi

    deploy_target_count="$(awk 'NF && $1 !~ /^#/ {count++} END {print count+0}' "$base_dir/server")"

    if [[ ! "$deploy_target_count" =~ ^[0-9]+$ || "$deploy_target_count" -lt 1 ]]; then
        echo "file_deploy 실행 대상이 없습니다: $base_dir/server"
        return 1
    fi

    # 파일 크기에 따른 file_deploy 안전 분할 기준
    deploy_default_chunk_size="$(__sage_file_deploy_chunk_size "$file_size")"

    # 기본값은 파일 크기에 따른 안전 분할 기준
    deploy_chunk_size="$deploy_default_chunk_size"

    # config에 JID_CHUNK_SIZE를 직접 지정한 경우 비교한다.
    #
    # config 값이 안전 기준보다 작으면 config 값을 사용하고,
    # 안전 기준보다 크면 안전 기준으로 제한한다.
    if [[ "${jid_chunk_size_declared:-0}" -eq 1 && -n "${JID_CHUNK_SIZE:-}" ]]; then
        if (( JID_CHUNK_SIZE < deploy_default_chunk_size )); then
            deploy_chunk_size="$JID_CHUNK_SIZE"
        elif (( JID_CHUNK_SIZE > deploy_default_chunk_size )); then
            printf '  안내: config의 JID_CHUNK_SIZE=%s는 file_deploy 안전 기준=%s보다 커서 %s로 제한합니다.\n' \
                "$JID_CHUNK_SIZE" \
                "$deploy_default_chunk_size" \
                "$deploy_default_chunk_size"
        fi
    fi

    # 실제 대상 수보다 분할 단위가 크면 대상 수로 제한한다.
    if (( deploy_chunk_size > deploy_target_count )); then
        deploy_chunk_size="$deploy_target_count"
    fi

    deploy_chunk_count=$(( (deploy_target_count + deploy_chunk_size - 1) / deploy_chunk_size ))

    file_deploy_call_no=$((file_deploy_call_no + 1))
    printf -v deploy_call_label '%04d' "$file_deploy_call_no"

    deploy_work_dir="$tmp_dir/file_deploy/$deploy_call_label"
    deploy_stage_dir="$file_deploy_stage_root/$deploy_call_label"
    deploy_stage_file="$deploy_stage_dir/source"
    deploy_salt_source="salt://sage_file_deploy/$sage_file_deploy_run_id/$deploy_call_label/source"
    success_file="$deploy_work_dir/success_hosts"
    fail_file="$deploy_work_dir/fail_hosts"

    rm -rf "$deploy_work_dir" "$deploy_stage_dir"
    mkdir -p \
        "$deploy_work_dir/log" \
        "$deploy_work_dir/result" \
        "$deploy_work_dir/error" \
        "$deploy_work_dir/.tmp" \
        "$deploy_stage_dir"

    awk 'NF && $1 !~ /^#/ {print $1}' "$base_dir/server" | sort -u > "$deploy_work_dir/server"

    # 같은 파일시스템이면 데이터 복사 없이 hard link를 사용한다.
    # hard link가 불가능한 경우에만 권한/시간을 유지해 복사한다.
    if ! ln -- "$source_file" "$deploy_stage_file" 2>/dev/null; then
        if ! cp -p -- "$source_file" "$deploy_stage_file"; then
            echo "file_deploy source staging 실패: $source_file"
            return 1
        fi
    fi

    deploy_server_list="$(paste -sd, "$deploy_work_dir/server")"

    # Salt fileserver는 file list를 캐시하므로 실행 중 새로 만든 staging source가
    # 즉시 보이도록 roots backend의 base 환경 file list cache를 비운다.
    deploy_salt_run_bin="${SALT_RUN_BIN:-/usr/bin/salt-run}"

    if [[ ! -x "$deploy_salt_run_bin" ]]; then
        deploy_salt_run_bin="$(command -v salt-run 2>/dev/null || true)"
    fi

    if [[ -z "$deploy_salt_run_bin" || ! -x "$deploy_salt_run_bin" ]]; then
        echo "file_deploy salt-run 명령을 찾을 수 없습니다."
        return 1
    fi

    set +e
    "$deploy_salt_run_bin" \
        fileserver.clear_file_list_cache \
        saltenv=base \
        backend=roots \
        >/dev/null 2>&1
    fileserver_cache_rc=$?
    set -e

    if [[ "$fileserver_cache_rc" -ne 0 ]]; then
        echo "file_deploy fileserver cache 초기화 실패: rc=$fileserver_cache_rc"
        return 1
    fi

	# file_deploy 기본 대기 시간은 7200초이며,
	# 필요할 경우 FILE_DEPLOY_WAIT_TIMEOUT으로 별도 조정한다.
	if [[ ! "$deploy_wait_timeout" =~ ^[0-9]+$ ]]; then
		echo "FILE_DEPLOY_WAIT_TIMEOUT은 0 이상의 정수여야 합니다: $deploy_wait_timeout"
		return 1
	fi

	sage_print_subsection "file_deploy"
	printf '    원본 파일 : %s\n' "$source_file"
	printf '    대상 경로 : %s\n' "$destination_file"
	echo
	echo "    배포 정보"
	printf '      전체 대상 : %s대\n' "$deploy_target_count"
	printf '      분할 단위 : %s대\n' "$deploy_chunk_size"
	printf '      실행 횟수 : 총 %s회\n' "$deploy_chunk_count"
	echo

    set +e
    (
        export home_dir="$home_dir"
        export framework_dir="$framework_dir"
        export apply_dir="$apply_dir"
        export base_dir="$deploy_work_dir"
        export log_dir="$deploy_work_dir/log"
        export result_dir="$deploy_work_dir/result"
        export error_dir="$deploy_work_dir/error"
        export tmp_dir="$deploy_work_dir/.tmp"
        export RESULT_STATUS_FILE="$deploy_work_dir/.tmp/result_status"
        export server_list="$deploy_server_list"
        export server_count="$deploy_target_count"

        export TIMEOUT="${TIMEOUT:-3}"
        export ASYNC=false
        export COLLECT_BY_JID=true
        export JID_CHUNK_SIZE="$deploy_chunk_size"
        export POLL_INTERVAL="${POLL_INTERVAL:-3}"
        export JOB_WAIT_TIMEOUT="$deploy_wait_timeout"
        export RUNNING_CHECK_INTERVAL="${RUNNING_CHECK_INTERVAL:-30}"
        export LATE_CHECK_TIMEOUT="${LATE_CHECK_TIMEOUT:-5}"
        export LATE_CHECK_HARD_TIMEOUT="${LATE_CHECK_HARD_TIMEOUT:-15}"
        export LOOKUP_HARD_TIMEOUT="${LOOKUP_HARD_TIMEOUT:-30}"
        export FINAL_LOOKUP_HARD_TIMEOUT="${FINAL_LOOKUP_HARD_TIMEOUT:-300}"
        export PING_CHECK_PARALLEL="${PING_CHECK_PARALLEL:-10}"
        export PING_RETRY_COUNT="${PING_RETRY_COUNT:-2}"
        export PING_RETRY_SLEEP="${PING_RETRY_SLEEP:-2}"
        export DEBUG_MODE="${DEBUG_MODE:-false}"
        export DEBUG_PRINT="${DEBUG_PRINT:-false}"
        export DEBUG_LOG="$deploy_work_dir/log/debug.log"
        export SALT_APPLY_CONTEXT=file_deploy
        export SAGE_JOB_DIR
        export SAGE_FILE_DEPLOY_LABEL="$deploy_call_label"
        export SAGE_RUN_ID
        export JID_REGISTRY_FILE
        export JID_REGISTRY_LOCK_FILE

        SALT_FUNCTION="state.single"
        SALT_ARGS=(
            "file.managed"
            "name=$destination_file"
            "source=$deploy_salt_source"
            "mode=keep"
            "makedirs=True"
            "show_changes=False"
        )
        export SALT_FUNCTION

        . "$framework_dir/salt_apply"
        exit "${SALT_RC:-1}"
    )
    deploy_salt_rc=$?
    set -e

    # Salt 명령 자체가 실패해도 반환된 성공 host는 살리고,
    # 결과가 없거나 state result=False인 host만 배포 실패로 분류한다.
    __sage_file_deploy_parse_result \
        "$deploy_work_dir/log/log_salt" \
        "$deploy_work_dir/server" \
        "$success_file" \
        "$fail_file"

    success_count="$(wc -l < "$success_file")"
    fail_count="$(wc -l < "$fail_file")"

    if [[ -s "$fail_file" ]]; then
        while IFS= read -r host; do
            [[ -z "$host" ]] && continue
            __sage_file_deploy_append_error "$host" "$source_name"
        done < "$fail_file"

        fail_list="$(paste -sd, "$fail_file")"
    fi

    rm -rf "$deploy_stage_dir"

	echo
	sage_print_subsection "file_deploy 결과"
	printf '    대상 파일 : %s\n' "$source_name"
	printf '    성공/실패 : %s / %s\n' "$success_count" "$fail_count"
	echo

	if (( fail_count > 0 )); then
    	echo
    	echo "    실패 서버"
    	printf '      %s\n' "$fail_list"
	fi

    # 배포 실패는 error/<host>에 기록하되 기존 Mage 방식처럼
    # server 목록은 변경하지 않고 이후 local/remote를 계속 실행한다.
    # 원본/인자/staging 오류만 위에서 return 1로 처리한다.
    : "$deploy_salt_rc"
    return 0
}

# file_deploy는 Sage 예약 함수/변수다.
# local에서 같은 이름을 변수로 사용하거나 함수를 재정의하면 즉시 실패한다.
readonly -f file_deploy
readonly file_deploy=""

# ============================================================
# local 스크립트 실행
# ============================================================
# 최종 server 필터링 완료 후 Salt 실행 전에
# master 로컬에서 local 스크립트를 실행한다.
#
# local 파일이 없거나 주석/공백만 있으면 실행하지 않는다.
# local 실행 실패 시 전체 작업도 실패 처리한다.
# ============================================================
run_user_local() {
    local local_file="$base_dir/local"

    if ! has_user_local; then
        return 0
    fi

    sage_print_section "local 실행"

    (
        export SAGE_LOCAL_ACTIVE=1
        cd "$base_dir"
        . "$local_file"
    )
}

# ============================================================
# 이전 실행 결과 파일 정리
# ============================================================
rm -f "$log_dir/server_fail" "$log_dir/log_salt"

# ============================================================
# Sage 실행 요약 기본값
# ============================================================
# set -u 환경에서 분기 누락으로 미정의 변수가 발생하지 않도록
# 요약 출력 변수에 기본값을 설정한다.
server_summary="기존 파일 사용"
minion_summary="key 완료 / ping 완료"
pre_status="OFF"
# ============================================================
# 실행 전 사전 작업 및 대상 서버 목록 생성
#
# 우선순위
# 1. pre 파일에 유효한 실행 내용이 있으면 실행
#    - pre에서 server를 생성하면 해당 결과를 사용
# 2. pre가 없거나, 실제 실행 내용이 없거나, 실행 결과 server가 비어있으면 기존 server 파일 사용
# 3. 기존 server 파일도 없거나 비어있으면 종료
# ============================================================

pre_file="$base_dir/pre"
server_backup="$tmp_dir/server_before_pre"

# pre 실행 전에 기존 server 파일 백업
if [[ -s "$base_dir/server" ]]; then
    cp -f "$base_dir/server" "$server_backup"
else
    > "$server_backup"
fi

if [[ -f "$pre_file" ]]; then
    pre_effective="$tmp_dir/pre_effective"

    awk '
        /^[[:space:]]*#!/ { next }
       /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }

        /^[[:space:]]*\.[[:space:]]+"?\$home_dir\/common\/netbox_inventory\/function"?[[:space:]]*$/ { next }
        /^[[:space:]]*source[[:space:]]+"?\$home_dir\/common\/netbox_inventory\/function"?[[:space:]]*$/ { next }

        /^[[:space:]]*\.[[:space:]]+"?\$\{home_dir\}\/common\/netbox_inventory\/function"?[[:space:]]*$/ { next }
        /^[[:space:]]*source[[:space:]]+"?\$\{home_dir\}\/common\/netbox_inventory\/function"?[[:space:]]*$/ { next }

        /^[[:space:]]*\.[[:space:]]+"?\/data\/salt\/common\/netbox_inventory\/function"?[[:space:]]*$/ { next }
        /^[[:space:]]*source[[:space:]]+"?\/data\/salt\/common\/netbox_inventory\/function"?[[:space:]]*$/ { next }

        { print }
    ' "$pre_file" > "$pre_effective"

    if [[ -s "$pre_effective" ]]; then
        pre_status="ON"
      # pre가 server를 새로 생성하는지 확인하기 위해 기존 server는 비우고 실행
      > "$base_dir/server"

        # pre는 별도 서브셸에서 실행한다.
        # 상대경로와 pwd는 현재 job 디렉토리($base_dir)를 기준으로 동작한다.
        # pre에서 변경한 변수, 함수, 작업 디렉토리는 Sage 본체에 영향을 주지 않는다.
        (
            cd "$base_dir"
            . "$pre_file"
        )

        if [[ ! -s "$base_dir/server" ]]; then
            if [[ -s "$server_backup" ]]; then
                cp -f "$server_backup" "$base_dir/server"
                server_summary="기존 파일 사용"
          else
                echo "pre 실행 결과 server 파일이 없거나 비어있습니다."
                echo "확인 경로: $base_dir/server"
              exit 1
            fi
        else
            server_summary="pre 사용"
      fi
    else
        if [[ ! -s "$base_dir/server" ]]; then
            echo "⏹       $base_dir/server 파일이 없거나 비어있습니다."
            exit 1
        fi

    fi
else
    if [[ ! -s "$base_dir/server" ]]; then
        echo "⏹       $base_dir/server 파일이 없거나 비어있습니다."
        exit 1
    fi

fi

# server 파일에서 중복을 제거한 전체 대상 목록 생성
awk 'NF && $1 !~ /^#/ {print $1}' "$base_dir/server" | sort -u > "$tmp_dir/server_target"

if [[ ! -s "$tmp_dir/server_target" ]]; then
    echo "⏹       server 대상 목록이 비어있습니다."
    exit 1
fi

# ============================================================
# Salt에 등록된 accepted minion 목록 생성
# ============================================================

accepted_nodes="${KEY_FILE:-$framework_dir/__cache__/accepted_nodes}"
minion_summary="accepted_nodes 확인 / ping 완료"

if [[ ! -f "$accepted_nodes" ]]; then
    echo "accepted_nodes 없음: $accepted_nodes"
    exit 1
fi

awk '
    /^[[:space:]]*$/ {
        next
    }

    /^[[:space:]]*#/ {
        next
    }

    /^[[:space:]]*(Accepted|Unaccepted|Rejected|Denied)[[:space:]]+Keys:/ {
        next
    }

    {
        print $1
    }
' "$accepted_nodes" \
    | sort -u \
    > "$tmp_dir/server_accepted"

if [[ ! -s "$tmp_dir/server_accepted" ]]; then
    echo "accepted_nodes에 유효한 minion 목록이 없습니다: $accepted_nodes"
    exit 1
fi

# comm 비교를 위해 양쪽 파일 정렬
sort -u "$tmp_dir/server_target" -o "$tmp_dir/server_target"
sort -u "$tmp_dir/server_accepted" -o "$tmp_dir/server_accepted"

# 전체 대상 중 Salt key가 accepted 상태인 서버
comm -12 "$tmp_dir/server_target" "$tmp_dir/server_accepted" > "$tmp_dir/server_registered"

# 전체 대상 중 Salt key가 등록되지 않은 서버
comm -23 "$tmp_dir/server_target" "$tmp_dir/server_accepted" \
    | awk '{print $1 "\tnot_registered"}' > "$tmp_dir/server_fail_not_registered"

server_registered_list=$(paste -sd, "$tmp_dir/server_registered")

# ============================================================
# test.ping 옵션 구성
# TIMEOUT이 config에 있으면 ping에도 적용
# ============================================================
PING_OPT=()

if [[ -n "${TIMEOUT:-}" ]]; then
    PING_OPT+=(--timeout="$TIMEOUT")
fi

# ============================================================
# Salt test.ping 검사 여부 처리
#
# SKIP_PING=true 이면:
#   - test.ping 생략
#   - salt-key accepted 상태인 서버를 최종 실행 대상으로 사용
#
# SKIP_PING=false 또는 미설정이면:
#   - 기존처럼 test.ping 으로 응답 가능한 서버만 최종 실행 대상으로 사용
# ============================================================
case "${SKIP_PING:-false}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y)
		minion_summary="key 완료 / ping 생략"

        # ping 검사를 생략하므로 registered 서버 전체를 ping_ok로 간주
        cp -f "$tmp_dir/server_registered" "$tmp_dir/server_ping_ok"

        # ping 검사를 생략하므로 ping_fail은 없음
        > "$tmp_dir/server_fail_not_ping"
        ;;

    false|FALSE|False|0|no|NO|No|n|N|"")
		minion_summary="key 완료 / ping 완료"

        if [[ -n "$server_registered_list" ]]; then
            salt -L "$server_registered_list" \
                "${PING_OPT[@]}" \
                test.ping --out=json 2>/dev/null \
                | jq -r 'to_entries[] | select(.value == true) | .key' \
                | sort -u > "$tmp_dir/server_ping_ok"
        else
            > "$tmp_dir/server_ping_ok"
        fi

        # Salt key는 있지만 ping 실패한 서버
        sort -u "$tmp_dir/server_registered" -o "$tmp_dir/server_registered"
        sort -u "$tmp_dir/server_ping_ok" -o "$tmp_dir/server_ping_ok"

        comm -23 "$tmp_dir/server_registered" "$tmp_dir/server_ping_ok" \
            | awk '{print $1 "\tping_fail"}' > "$tmp_dir/server_fail_not_ping"
        ;;

    *)
        echo "SKIP_PING 값이 올바르지 않습니다: ${SKIP_PING}"
        echo "사용 가능 값: true, false"
        exit 1
        ;;
esac

# comm 비교를 위해 정렬
sort -u "$tmp_dir/server_registered" -o "$tmp_dir/server_registered"
sort -u "$tmp_dir/server_ping_ok" -o "$tmp_dir/server_ping_ok"

# 최종 실행 대상 서버
comm -12 "$tmp_dir/server_registered" "$tmp_dir/server_ping_ok" > "$tmp_dir/server_final"

# ============================================================
# dirty_nodes 제외 처리
# ============================================================
# $dirty_nodes_file 에 등록된 서버는 salt-key/ping 검사를 통과했더라도
# 최종 실행 대상에서 제외한다.
# 제외 사유는 server_fail 에 dirty_nodes 로 기록한다.
#
# 입력 파일 형식:
#   - 한 줄에 host 하나
#   - 빈 줄 무시
#   - # 으로 시작하는 주석 무시
# ============================================================
> "$tmp_dir/server_fail_dirty_nodes"

if [[ -f "$dirty_nodes_file" ]]; then
    awk 'NF && $1 !~ /^#/ {print $1}' "$dirty_nodes_file" | sort -u > "$tmp_dir/dirty_nodes"

    if [[ -s "$tmp_dir/dirty_nodes" ]]; then
        sort -u "$tmp_dir/server_final" -o "$tmp_dir/server_final"

        # 최종 실행 대상과 dirty_nodes 의 교집합만 제외 대상으로 기록
        comm -12 "$tmp_dir/server_final" "$tmp_dir/dirty_nodes" \
            | awk '{print $1 "\tdirty_nodes"}' > "$tmp_dir/server_fail_dirty_nodes"

        # dirty_nodes 에 있는 서버를 최종 실행 대상에서 제거
        comm -23 "$tmp_dir/server_final" "$tmp_dir/dirty_nodes" > "$tmp_dir/server_final.clean"
        mv "$tmp_dir/server_final.clean" "$tmp_dir/server_final"
    fi
else
    > "$tmp_dir/dirty_nodes"
fi

# 최종 실행 대상 server 파일 갱신
mv "$tmp_dir/server_final" "$base_dir/server"

# 제외 서버 목록 통합
cat "$tmp_dir/server_fail_not_registered" \
    "$tmp_dir/server_fail_not_ping" \
    "$tmp_dir/server_fail_dirty_nodes" \
    | awk 'NF {print $1 "\t" $2}' \
    | sort -k1,1 \
    > "$log_dir/server_fail"

if [[ ! -s "$base_dir/server" ]]; then
    echo "최종 실행 가능한 서버가 없습니다."
    echo "제외 서버 목록: $log_dir/server_fail"
    exit 1
fi

# ============================================================
# 실행 대상/제외 대상 및 실행 정보 요약
# ============================================================
server_list=$(paste -sd, "$base_dir/server")
server_count=$(wc -l < "$base_dir/server")
skip_count=$(wc -l < "$log_dir/server_fail")

# ============================================================
# JID_CHUNK_SIZE 자동 적용
# ============================================================
# config에 JID_CHUNK_SIZE를 직접 선언하지 않은 경우에만 적용한다.
#
# 적용 조건:
#   - ASYNC=false
#   - COLLECT_BY_JID=true
#   - 최종 실행 대상이 200대 초과
#
# 위 조건을 모두 만족하면 JID_CHUNK_SIZE=200을 자동 적용한다.
# ============================================================
if [[ "$jid_chunk_size_declared" -eq 0 ]]; then
    case "${ASYNC:-false}" in
        true|TRUE|True|1|yes|YES|Yes|y|Y)
            JID_CHUNK_SIZE=""
            ;;

        *)
            case "${COLLECT_BY_JID:-true}" in
                true|TRUE|True|1|yes|YES|Yes|y|Y)
                    if (( server_count > 200 )); then
                        JID_CHUNK_SIZE=200
                    else
                        JID_CHUNK_SIZE=""
                    fi
                    ;;

                *)
                    JID_CHUNK_SIZE=""
                    ;;
            esac
            ;;
    esac
fi

ASYNC_RESULT_MODE=0
case "${ASYNC_RESULT:-false}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y)
        ASYNC_RESULT_MODE=1
        detect_framework_exec_master_info
        ;;
esac

jid_chunk_count=0
if [[ -n "${JID_CHUNK_SIZE:-}" ]]; then
    jid_chunk_count=$(( (server_count + JID_CHUNK_SIZE - 1) / JID_CHUNK_SIZE ))
fi

if (( server_count == 0 )); then
    echo "실행 대상 없음"
    exit 1
fi

# 실행 전 작업 파일과 필수 인자를 검증한다.
# 정상일 때는 출력하지 않고, 검증 실패 시 오류만 출력한다.
job_validation_output=""
if ! job_validation_output="$(validate_job 2>&1)"; then
    printf '%s\n' "$job_validation_output"
    exit 1
fi

local_status="OFF"
if has_user_local; then
	local_status="ON"
fi

post_status="OFF"
if post_has_effective_content "$base_dir/post"; then
    case "${ASYNC:-false}" in
        true|TRUE|True|1|yes|YES|Yes|y|Y)
            if [[ "$ASYNC_RESULT_MODE" -eq 1 ]]; then
                post_status="ON"
            fi
            ;;
        *)
            post_status="ON"
            ;;
    esac
fi

# ============================================================
# 실제 Salt 실행 방식 표시
# ============================================================
# sage 실행 정보의 가운데 항목과 실제 실행 섹션 제목을
# SALT_FUNCTION/SALT_ARGS 기준으로 결정한다.
salt_execution_name="Salt"
salt_section_title="Salt 실행"

case "$SALT_FUNCTION" in
    cmd.run)
        if [[ "${SALT_ARGS[0]:-}" == "__RUN_SCRIPT__" ]]; then
            salt_execution_name="remote"
            salt_section_title="remote 실행"
        else
            salt_execution_name="cmd.run"
            salt_section_title="cmd.run 실행"
        fi
        ;;

    state.apply)
        salt_execution_name="state.apply"
        salt_section_title="state.apply 실행"
        ;;

    state.single)
        if [[ "${SALT_ARGS[0]:-}" == "file.managed" ]]; then
            salt_execution_name="file.managed"
            salt_section_title="file.managed 실행"
        else
            salt_execution_name="state.single"
            salt_section_title="state.single 실행"
        fi
        ;;
esac

# ============================================================
# Sage 실행 정보 요약
# ============================================================

sage_print_section "sage 실행 정보"
printf '  server : %s\n' "${server_summary:-기존 파일 사용}"
printf '  minion : %s\n' "${minion_summary:-key 완료 / ping 완료}"
echo
printf '  %-13s : %s\n' "pre" "$pre_status"
printf '  %-13s : %s\n' "local" "$local_status"
printf '  %-13s : %s\n' "$salt_execution_name" "ON"
printf '  %-13s : %s\n' "post" "$post_status"

sage_print_section "실행 모드"

printed_mode_option=0

if (( ${#config_declared_options[@]} > 0 )); then
    for option_name in "${config_declared_options[@]}"; do

        # 실제 JID_CHUNK_SIZE가 사용 중이면 아래 상세 영역에서 출력한다.
		if [[ "$option_name" == "JID_CHUNK_SIZE" && -n "${JID_CHUNK_SIZE:-}" ]]; then
            continue
        fi

        # EVENT_NOTIFY_LIB는 ASYNC_RESULT=true에서만 의미가 있다.
        if [[ "$option_name" == "EVENT_NOTIFY_LIB" && "${ASYNC_RESULT_MODE:-0}" -ne 1 ]]; then
            continue
        fi

        printf '  %-17s : %s\n' \
            "$option_name" \
            "${config_declared_values[$option_name]-}"
        printed_mode_option=1
    done
fi

if [[ "$printed_mode_option" -eq 0 && -z "${JID_CHUNK_SIZE:-}" ]]; then
    echo "  별도 설정 없음 / 기본값 사용"
fi

if [[ -n "${JID_CHUNK_SIZE:-}" ]]; then
    printf '  %-17s : %s\n' "JID_CHUNK_SIZE" "$JID_CHUNK_SIZE"
    printf '  %-17s : %s대\n' "전체 대상" "$server_count"
    printf '  %-17s : %s대\n' "분할 단위" "$JID_CHUNK_SIZE"
    if [[ "${JID_CHUNK_RANDOMIZE:-true}" == "false" ]]; then
        printf '  %-17s : %s\n' "분할 순서" "정렬 순서"
    else
        printf '  %-17s : %s\n' "분할 순서" "랜덤 셔플"
    fi
    printf '  %-17s : 총 %s회\n' "실행 횟수" "$jid_chunk_count"
fi

echo
case "${ASYNC:-false}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y)
        if [[ "${ASYNC_RESULT_MODE:-0}" -eq 1 ]]; then
            echo "  → Salt job 등록 후 event 결과 수집"
		else
            echo "  → Salt job 등록 후 종료"
		fi
        ;;
    *)
        echo "  → Salt 결과 수집 후 종료"
		;;
esac

if (( skip_count > 0 )); then
    sage_print_section "제외 서버 : ${skip_count}대"
    printf '  '
	awk '{print $1 "(" $2 ")"}' "$log_dir/server_fail" | paste -sd,
fi

sage_print_section "실행 대상 : ${server_count}대"
printf '  '
paste -sd, "$base_dir/server"

echo
sage_print_line
echo
# ============================================================
# 사용자 실행 확인
# -y 옵션이 있으면 자동 yes 처리
# ============================================================
if [[ $AUTO_YES -eq 1 ]]; then
    answer="y"
else
	read -r -p "이 서버들에 대해 실행하시겠습니까? (Y/n): " answer
fi

case "$answer" in
    [Yy]|"")
        # salt_apply/post에서 사용할 변수 export
        export home_dir base_dir framework_dir log_dir result_dir error_dir tmp_dir server_list server_count apply_dir
		export FRAMEWORK_EXEC_MASTER FRAMEWORK_EXEC_MASTER_IPS
        export SAGE_RUN_ID JID_REGISTRY_FILE JID_REGISTRY_LOCK_FILE
        [[ -n "${BATCH:-}" ]] && export BATCH
        [[ -n "${TIMEOUT:-}" ]] && export TIMEOUT
        [[ -n "${ASYNC:-}" ]] && export ASYNC
        [[ -n "${ASYNC_RESULT:-}" ]] && export ASYNC_RESULT
        [[ -n "${COLLECT_BY_JID:-}" ]] && export COLLECT_BY_JID
        [[ -n "${JID_CHUNK_SIZE:-}" ]] && export JID_CHUNK_SIZE
        [[ -n "${JID_CHUNK_RANDOMIZE:-}" ]] && export JID_CHUNK_RANDOMIZE
        [[ -n "${POLL_INTERVAL:-}" ]] && export POLL_INTERVAL
        [[ -n "${JOB_WAIT_TIMEOUT:-}" ]] && export JOB_WAIT_TIMEOUT
        [[ -n "${LATE_CHECK_TIMEOUT:-}" ]] && export LATE_CHECK_TIMEOUT
        export DEBUG_MODE DEBUG_PRINT DEBUG_LOG
        export SALT_FUNCTION

        # 원본 Sage 작업 경로
        # file_deploy 내부에서 base_dir이 임시 작업 경로로 변경되어도
        # sage_history.log의 JOB에는 원래 작업 경로를 사용한다.
        SAGE_JOB_DIR="$base_dir"
        export SAGE_JOB_DIR

        if [[ ! -f "$framework_dir/salt_apply" ]]; then
            echo "salt_apply 파일 없음: $framework_dir/salt_apply"
            exit 1
        fi

        # local 스크립트 실행
        # 최종 server 필터링 완료 후, Salt 실행 전에 master 로컬에서 수행한다.
		run_user_local
		
		sage_print_section "$salt_section_title"
				
		. "$framework_dir/salt_apply"

        if [[ "${SALT_RC:-1}" -ne 0 ]]; then
            echo
            echo "  Salt 실행 실패 또는 로그 파싱 불가"
            echo
            sage_print_line
            exit 1
        fi

		case "${ASYNC:-false}" in
		    true|TRUE|True|1|yes|YES|Yes|y|Y)
		        sage_print_section "실행 완료"
		        echo "  Salt job 등록 완료"
		
		        if [[ "${ASYNC_RESULT_MODE:-0}" -eq 1 ]]; then
		            echo "  결과 수집 : event listener"
		
		            if [[ "$KEEP_TMP" -eq 1 ]]; then
		                echo "  .tmp      : --keep-tmp 옵션으로 유지"
		            else
		                echo "  .tmp      : listener 전체 결과 수신 완료 후 자동 삭제"
		            fi
		
		        elif [[ -n "${SAGE_LAST_JID:-}" ]]; then
		            printf '  결과 조회 : salt-run jobs.lookup_jid %s --out=json\n' "$SAGE_LAST_JID"
		        fi
		
		        echo
		        sage_print_line
		        exit 0
		        ;;
		esac

        # log_salt 파싱 후 result/error 디렉토리에 호스트별 결과 생성
        run_post

        sage_print_section "결과 정리"
        printf '  result : %s개\n' "${RESULT_FILE_COUNT:-0}"
        printf '  error  : %s개\n' "${ERROR_FILE_COUNT:-0}"

        # result/error 생성 완료 후 사용자 post 스크립트 실행
        run_user_post

        echo
        sage_print_line
        ;;

    *)
        echo "⏹           실행이 취소되었습니다."
        exit 0
        ;;
esac
