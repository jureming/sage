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
#   $base_dir/local
#   $base_dir/remote
#   $base_dir/post
#   $base_dir/server
#   $framework_dir/salt_apply
#   $base_dir/log/server_fail
#   $base_dir/log/log_salt
#   $base_dir/log/async_jid
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
    echo "사용법: sage [-y|--yes] [--keep-tmp] [-d|--debug] [-i|--init <작업경로>] [manual/작업분류/작업명|cron/작업분류/작업명|절대경로]"
	echo
	echo "  경로 생략 시 현재 디렉토리를 작업 디렉토리로 사용합니다."
    echo
	echo "  -y, --yes            : 실행 확인 질문 없이 바로 실행합니다."
    echo "  --keep-tmp           : 종료 후 .tmp 디렉토리를 삭제하지 않습니다."
    echo "  -d, --debug          : 디버그 모드 활성화(debug.log 기록 + 화면 출력)."
    echo "  -i, --init <작업명>  : sample 디렉토리를 복사해 새 작업 디렉토리를 생성합니다."
    echo "                         현재 디렉토리 기준으로 생성합니다(절대경로도 가능)."
    echo "                         예) sage -i backup"
    echo "  -h, --help           : 이 도움말을 출력합니다."
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

    echo "============================================================"
    echo "신규 작업 디렉토리 생성 완료"
    echo "============================================================"
    echo "  원본 : $sample_dir"
    echo "  생성 : $dest_dir"
    echo "------------------------------------------------------------"
    echo "다음 파일을 작업에 맞게 수정하세요:"
    echo "  README : 작업 기본 정보(작업명/설명/작성자 등)"
    echo "  config : 서버 목록 생성(make_server) 및 실행 옵션"
    echo "  remote : 대상 서버에서 실행할 명령"
    echo "  local  : (선택) Salt 실행 전 master 로컬 사전 작업"
    echo "  post   : (선택) 실행 결과 정리 후 후처리"
    echo "------------------------------------------------------------"
    echo "실행 예: cd $dest_dir && sage"
    echo "============================================================"
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
# config/local/remote/post는 Bash 기반 파일이므로
# config source 및 server/minion 처리 전에 bash -n으로 검사한다.
# 하나라도 문법 오류가 있으면 전체 오류를 출력한 뒤 실행을 중단한다.
# ============================================================
validate_job_bash_syntax() {
    local -a check_names=("config" "local" "remote" "post")
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
        # local/remote/post는 파일이 있을 때만 문법 검사한다.
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

# config/local/remote/post Bash 문법 검사
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

# ============================================================
# 실행 산출물 디렉토리 초기화
# 중복 실행 lock을 잡은 뒤에만 지운다.
# ============================================================
log_dir="$base_dir/log"
result_dir="$base_dir/result"
error_dir="$base_dir/error"
tmp_dir="$base_dir/.tmp"

rm -rf "$log_dir" "$result_dir" "$error_dir" "$tmp_dir"

mkdir -p "$log_dir"
mkdir -p "$result_dir"
mkdir -p "$error_dir"
mkdir -p "$tmp_dir"

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
# async_jid, debug.log, log_salt, server_fail 은 모두 이 디렉토리에 저장한다.
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
#   - 최종 server 목록을 청크 단위로 나눠 JID 기반으로 순차 실행한다.
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
# 종료 시 임시 디렉토리 정리
# ============================================================
cleanup() {
    if [[ "$KEEP_TMP" -eq 1 ]]; then
        echo "[DEBUG] tmp 유지: $tmp_dir"
    else
        rm -rf "$tmp_dir"
    fi


    if [[ "${LOCK_ACQUIRED:-0}" -eq 1 && -n "${lock_file:-}" ]]; then
        rm -f "$lock_file"
    fi
}

trap cleanup EXIT INT TERM

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

    # 이전 결과 초기화
    rm -rf "$result_dir" "$error_dir"
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

    with open(path, "w", encoding="utf-8") as out:
        if content:
            out.write(content + "\n")
        else:
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

            # 최종 파싱에서 이미 result 또는 error가 만들어졌으면 중복 기록하지 않는다.
            if [[ -f "$result_dir/$host" || -f "$error_dir/$host" ]]; then
                continue
            fi

            printf '%s\n' "$status" > "$error_dir/$host"
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

        if [[ ! -f "$result_dir/$host" && ! -f "$error_dir/$host" ]]; then
            echo "no_return" > "$error_dir/$host"
        fi
    done < "$server_file"

    result_count="$(find "$result_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)"
    error_count="$(find "$error_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)"
    echo "정상 결과 파일 생성 완료: $result_dir (${result_count}개)"
    echo "에러 파일 생성 완료: $error_dir (${error_count}개)"
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

    echo
    echo "post 스크립트 실행중..."

    set +e
    (
        . "$post_file"
    )
    user_post_rc=$?
    set -e

    if [[ "$user_post_rc" -ne 0 ]]; then
        echo "post 스크립트 실패"
    else
        echo "post 스크립트 실행 완료"
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

    echo
    echo "[ local 실행 ]"

    (
        cd "$base_dir"
        . "$local_file"
    )
}

# ============================================================
# sage Salt 실행 히스토리 기록
# ============================================================
# salt_apply 실행 후 전역 히스토리 로그를 남긴다.
#
# 기록 위치:
#   /var/log/salt/sage_history.log
#
# 일반 실행:
#   날짜시간    JOB: 작업경로    JID: Salt_JID    SALT_RC: 결과코드
#
# JID_CHUNK_SIZE 실행:
#   - 청크별 JID, 대상 수, 결과코드 기록
#   - 마지막에 전체 청크 완료 요약 기록
#
# 주의:
#   - Bash 문법 검사 실패, 실행 전 검증 실패, 사용자 취소는 기록하지 않는다.
#   - 히스토리 기록 실패가 Salt 작업 실패로 이어지지 않도록 오류를 무시한다.
#   - async_jid 파일이 없으면 JID는 no_jid로 기록한다.
# ============================================================
write_sage_history() {
    local history_dir="/var/log/salt"
    local history_log="$history_dir/sage_history.log"
    local history_jid="no_jid"
    local history_rc="${SALT_RC:-unknown}"
    local chunk_line=""
    local chunk_label=""
    local chunk_jid=""
    local chunk_targets=""
    local chunk_rc=""
    local chunk_total=""
    local chunk_done=""

    {
        mkdir -p "$history_dir"

        if [[ -s "$log_dir/async_jid" ]] && grep -Eq '^[0-9]+/[0-9]+[[:space:]]+' "$log_dir/async_jid"; then
            while IFS=$'\t' read -r chunk_label chunk_jid chunk_targets chunk_rc; do
                [[ -z "${chunk_label:-}" ]] && continue
                [[ -z "${chunk_jid:-}" ]] && continue
                [[ -z "${chunk_targets:-}" ]] && chunk_targets="unknown"
                [[ -z "${chunk_rc:-}" ]] && chunk_rc="$history_rc"

                printf '%s\tJOB: %s\tJID_CHUNK: %s\tJID: %s\tTARGETS: %s\tSALT_RC: %s\n' \
                    "$(date '+%F %T')" \
                    "$base_dir" \
                    "$chunk_label" \
                    "$chunk_jid" \
                    "$chunk_targets" \
                    "$chunk_rc" \
                    >> "$history_log"
            done < "$log_dir/async_jid"

            chunk_total="$(awk -F '[\t/]' 'NF >= 2 {v=$2} END {print v}' "$log_dir/async_jid")"
            chunk_done="$(awk -F '[\t/]' 'NF >= 2 {v=$1} END {print v}' "$log_dir/async_jid")"

            [[ -z "$chunk_total" ]] && chunk_total="unknown"
            [[ -z "$chunk_done" ]] && chunk_done="unknown"

            printf '%s\tJOB: %s\tJID_CHUNK_SUMMARY: %s/%s\tTOTAL_TARGETS: %s\tSALT_RC: %s\n' \
                "$(date '+%F %T')" \
                "$base_dir" \
                "$chunk_done" \
                "$chunk_total" \
                "${server_count:-unknown}" \
                "$history_rc" \
                >> "$history_log"
        else
            if [[ -s "$log_dir/async_jid" ]]; then
                history_jid="$(head -n 1 "$log_dir/async_jid" | tr -d '\r\n')"
            fi

            printf '%s\tJOB: %s\tJID: %s\tSALT_RC: %s\n' \
                "$(date '+%F %T')" \
                "$base_dir" \
                "$history_jid" \
                "$history_rc" \
                >> "$history_log"
        fi
    } 2>/dev/null || true
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

# ============================================================
# 대상 서버 목록 생성
#
# 우선순위
# 1. config 안에 유효한 make_server 함수가 있으면 실행
#    - make_server 함수는 $base_dir/server 파일을 생성해야 함
# 2. make_server 함수가 없거나, 실제 생성 로직이 없거나, 실행 결과가 비어있으면 기존 server 파일 사용
# 3. 기존 server 파일도 없거나 비어있으면 종료
# ============================================================

server_backup="$tmp_dir/server_before_make"

# make_server 실행 전에 기존 server 파일 백업
if [[ -s "$base_dir/server" ]]; then
    cp -f "$base_dir/server" "$server_backup"
else
    > "$server_backup"
fi

if declare -F make_server >/dev/null; then
    make_server_effective="$tmp_dir/make_server_effective"

    declare -f make_server | awk '
        /^[[:space:]]*make_server[[:space:]]*\(\)[[:space:]]*$/ { next }
        /^[[:space:]]*make_server[[:space:]]*\(\)[[:space:]]*\{[[:space:]]*$/ { next }
        /^[[:space:]]*\{[[:space:]]*$/ { next }
        /^[[:space:]]*\}[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }

        /^[[:space:]]*\.[[:space:]]+"?\$home_dir\/common\/function"?[[:space:]]*$/ { next }
        /^[[:space:]]*source[[:space:]]+"?\$home_dir\/common\/function"?[[:space:]]*$/ { next }

        /^[[:space:]]*\.[[:space:]]+"?\$\{home_dir\}\/common\/function"?[[:space:]]*$/ { next }
        /^[[:space:]]*source[[:space:]]+"?\$\{home_dir\}\/common\/function"?[[:space:]]*$/ { next }

        { print }
    ' > "$make_server_effective"

    if [[ -s "$make_server_effective" ]]; then
        # make_server 결과가 실제로 있는지 확인하기 위해 기존 server는 비우고 실행
        > "$base_dir/server"

        make_server
        if [[ ! -s "$base_dir/server" ]]; then
            if [[ -s "$server_backup" ]]; then
                cp -f "$server_backup" "$base_dir/server"
				server_summary="기존 파일 사용"
            else
				echo "make_server 실행 결과 server 파일이 없거나 비어있습니다."
				echo "확인 경로: $base_dir/server"
                exit 1
            fi
        else
            server_summary="config make_server 사용"
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
awk 'NF {print $1}' "$base_dir/server" | sort -u > "$tmp_dir/server_target"

if [[ ! -s "$tmp_dir/server_target" ]]; then
    echo "⏹       server 대상 목록이 비어있습니다."
    exit 1
fi

# ============================================================
# Salt에 등록된 accepted minion 목록 생성
# ============================================================
minion_summary="key 완료 / ping 완료"

salt-key -l accepted 2>/dev/null \
    | sed '1d;s/^[[:space:]]*//' \
    | awk 'NF' \
    | sort -u > "$tmp_dir/server_accepted"

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

remote_status="OFF"
if [[ "$SALT_FUNCTION" == "cmd.run" && "${SALT_ARGS[0]:-}" == "__RUN_SCRIPT__" ]]; then
    remote_status="ON"
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
# Sage 실행 정보 요약
# ============================================================
echo
echo "=========================================================================="
echo
echo "[ sage 실행 정보 ]"
echo "server : ${server_summary:-기존 파일 사용}"
echo "minion : ${minion_summary:-key 완료 / ping 완료}"
echo

printf 'local  : %-3s  %s\n' "$local_status" "$base_dir/local"
printf 'remote : %-3s  %s\n' "$remote_status" "$base_dir/remote"
printf 'post   : %-3s  %s\n' "$post_status" "$base_dir/post"
echo
echo "=========================================================================="
echo
echo "[ 실행 모드 ]"

if (( ${#config_declared_options[@]} > 0 )); then
    for option_name in "${config_declared_options[@]}"; do

        # JID_CHUNK_SIZE가 실제 사용 중이면
        # 아래 전용 영역에서 상세 내용을 함께 출력하므로 여기서는 제외
        if [[ "$option_name" == "JID_CHUNK_SIZE" && -n "${JID_CHUNK_SIZE:-}" ]]; then
            continue
        fi

        printf '%s=%s\n' \
            "$option_name" \
            "${config_declared_values[$option_name]-}"
    done
else
    echo "별도 설정 없음 / 기본값 사용"
fi

# ============================================================
# JID_CHUNK_SIZE 실행 정보
# ============================================================
# config 직접 설정 또는 대상 수 기준 자동 적용 여부와 관계없이
# 실제 JID_CHUNK_SIZE가 사용되는 경우에만 출력한다.
# ============================================================
if [[ -n "${JID_CHUNK_SIZE:-}" ]]; then
    echo
    echo "JID_CHUNK_SIZE=$JID_CHUNK_SIZE"
    echo "ㄴ 전체 대상 : ${server_count}대"
    echo "ㄴ 분할 단위 : ${JID_CHUNK_SIZE}대"
    echo "ㄴ 실행 횟수 : 총 ${jid_chunk_count}회"
fi

echo

case "${ASYNC:-false}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y)
        if [[ "${ASYNC_RESULT_MODE:-0}" -eq 1 ]]; then
            echo "Salt job 등록 후 event 결과 수집"
        else
            echo "Salt job 등록 후 종료"
        fi
        ;;

    *)
        if [[ -z "${JID_CHUNK_SIZE:-}" ]]; then
            echo "Salt 결과 수집 후 종료"
        fi
        ;;
esac

echo "=========================================================================="
if (( skip_count > 0 )); then
    echo
    echo "[ 제외 서버 : ${skip_count}대 ]"
    awk '{print $1 "(" $2 ")"}' "$log_dir/server_fail" | paste -sd,
fi

echo
echo "[ 실행 대상 : ${server_count}대 ]"
paste -sd, "$base_dir/server"
echo
echo "=========================================================================="
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
        [[ -n "${BATCH:-}" ]] && export BATCH
        [[ -n "${TIMEOUT:-}" ]] && export TIMEOUT
        [[ -n "${ASYNC:-}" ]] && export ASYNC
        [[ -n "${ASYNC_RESULT:-}" ]] && export ASYNC_RESULT
        [[ -n "${COLLECT_BY_JID:-}" ]] && export COLLECT_BY_JID
        [[ -n "${JID_CHUNK_SIZE:-}" ]] && export JID_CHUNK_SIZE
        [[ -n "${POLL_INTERVAL:-}" ]] && export POLL_INTERVAL
        [[ -n "${JOB_WAIT_TIMEOUT:-}" ]] && export JOB_WAIT_TIMEOUT
        [[ -n "${LATE_CHECK_TIMEOUT:-}" ]] && export LATE_CHECK_TIMEOUT
        export DEBUG_MODE DEBUG_PRINT DEBUG_LOG
        export SALT_FUNCTION

        # 실제 Salt 실행
        if [[ ! -f "$framework_dir/salt_apply" ]]; then
            echo "salt_apply 파일 없음: $framework_dir/salt_apply"
            exit 1
        fi

        # local 스크립트 실행
        # 최종 server 필터링 완료 후, Salt 실행 전에 master 로컬에서 수행한다.
        run_user_local

        . "$framework_dir/salt_apply"

        # sage 실행 히스토리 기록
        # salt_apply 실행 후 SALT_RC와 async_jid가 결정된 뒤 기록한다.
        write_sage_history

        if [[ "${SALT_RC:-1}" -ne 0 ]]; then
            echo "salt_apply 실패 또는 로그 파싱 불가"
            exit 1
        fi
        case "${ASYNC:-false}" in
            true|TRUE|True|1|yes|YES|Yes|y|Y)
                echo
                if [[ -s "$log_dir/async_jid" ]]; then
                    async_jid_value="$(cat "$log_dir/async_jid")"
                    echo
                    echo "============================================================"
                    echo "ASYNC JID"
                    echo "============================================================"
                    echo "$async_jid_value"
                    echo "------------------------------------------------------------"
                    echo "결과 조회 명령어:"
                    echo "salt-run jobs.lookup_jid $async_jid_value --out=json"
                fi

                exit 0
                ;;
        esac

        echo
        echo "result 폴더에 결과 생성중..."

        # log_salt 파싱 후 result/error 디렉토리에 호스트별 결과 생성
        run_post

        # result/error 생성 완료 후 사용자 post 스크립트 실행
        run_user_post
        ;;

    *)
        echo "⏹           실행이 취소되었습니다."
        exit 0
        ;;
esac

