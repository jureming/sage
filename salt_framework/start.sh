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
#   sage -y manual/108231ju/sample
#
# cron 예:
#   * * * * /usr/local/bin/sage -y manual/108231ju/sample
#
# 중요한 점:
#   - framework_dir은 공통 프레임워크 소스 위치다.
#   - base_dir은 sage 인자 또는 현재 디렉토리로 결정되는 실제 작업 디렉토리다.
#   - config를 source 한 뒤에도 모든 파일과 디렉토리는
#     sage/start.sh가 결정한 $base_dir 기준으로 처리한다.
#
# config 로드 후 기준 경로:
#   $base_dir/config
#   $framework_dir/salt_apply
#   $base_dir/post
#   $base_dir/server
#   $base_dir/log/server_fail
#   $base_dir/log/log_salt
#   $base_dir/log/async_jid
#   $base_dir/log/debug.log
#   $base_dir/.tmp/result_status
#   $base_dir/result/*
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
    echo "  경로 생략 시 현재 디렉토리를 작업 디렉토리로 사용합니다."
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
# config 로드 및 필수 변수 검증
# ============================================================
if [[ ! -f "$config_file" ]]; then
    echo "config 파일 없음: $config_file"
    exit 1
fi

source "$config_file"

# config에 같은 변수가 남아 있어도 무시하고 sage/start.sh 기준값으로 강제 고정
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
# config에는 노출하지 않지만, 필요하면 DIRTY_NODES_FILE 변수로 경로 override 가능.
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
# 이 모드에서는 minion의 remote stdout/stderr/exit code를 event로 보내고,
# master listener가 result/error를 생성한 뒤 post를 1회 실행한다.
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
#   - 비어있거나 0이면 기존 동작
#   - 양의 정수이면 최종 server 목록을 지정한 개수만큼 나눠
#     JID 기반으로 순차 실행
#
# 제한:
#   - ASYNC=true 와 같이 사용할 수 없다.
#   - COLLECT_BY_JID=false 와 같이 사용할 수 없다.
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
# 파일 미리보기 출력 함수
# - state.apply SLS 내용
# - cmd.run 스크립트 내용
# 등을 실행 전 확인용으로 출력
# ============================================================
show_file_preview() {
    local title="$1"
    local file="$2"
    local max_lines="${3:-80}"
    local line_count

    line_count=$(wc -l < "$file")

    echo
    echo "============================================================"
    echo "$title"
    echo "============================================================"
    echo "파일: $file"
    echo "------------------------------------------------------------"
    head -n "$max_lines" "$file"

    if (( line_count > max_lines )); then
        echo "..."
        echo "[INFO] ${max_lines}줄까지만 표시"
    fi

    #echo "------------------------------------------------------------"
}

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
# 실행 전 작업 검증 및 미리보기
# 지원 SALT_FUNCTION:
#   - state.apply
#   - cmd.run
#   - state.single
# ============================================================
validate_and_preview_job() {
    case "$SALT_FUNCTION" in
        state.apply)
            local sls_name="${SALT_ARGS[0]}"
            local sls_file

            # state.apply 대상 SLS 파일 존재 여부 확인
            if ! sls_file=$(find_sls_file "$sls_name"); then
                echo
                echo "SLS 파일 없음"
                echo "확인 경로:"
                echo "  $apply_dir/${sls_name}/init.sls"
                exit 1
            fi

            if [[ ! -s "$sls_file" ]]; then
                echo "SLS 파일이 비어있습니다: $sls_file"
                exit 1
            fi

            # SLS 내부 salt:// source 파일 사전 검증
            validate_salt_sources_in_sls "$sls_file"

            # 실행 전 SLS 내용 미리보기
            show_file_preview "state.apply 모드" "$sls_file"
            echo
            ;;

        cmd.run)
            # __RUN_SCRIPT__ 모드는 RUN_SCRIPT 파일 내용을 대상 서버에서 실행
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

               # 실행 전 스크립트 내용 미리보기
               show_file_preview "cmd.run 모드" "$RUN_SCRIPT"
           else
               # 일반 cmd.run 명령어 출력
               echo
               echo "============================================================"
               echo "cmd.run 모드"
               echo "============================================================"
               printf '%s\n' "${SALT_ARGS[@]}"
               #echo "------------------------------------------------------------"
           fi

           echo
           ;;

       state.single)
           local state_mod="${SALT_ARGS[0]:-}"

           # state.single file.managed 전용 검증 및 출력
           if [[ "$state_mod" == "file.managed" ]]; then
               local src=""
               local dst=""
               local src_file=""
               local mode=""
               local user=""
               local group=""
               local makedirs=""
               local replace=""

               # SALT_ARGS 배열에서 file.managed 인자 추출
               for arg in "${SALT_ARGS[@]}"; do
                   case "$arg" in
                       name=*) dst="${arg#name=}" ;;
                       source=*) src="${arg#source=}" ;;
                       mode=*) mode="${arg#mode=}" ;;
                       user=*) user="${arg#user=}" ;;
                       group=*) group="${arg#group=}" ;;
                       makedirs=*) makedirs="${arg#makedirs=}" ;;
                       replace=*) replace="${arg#replace=}" ;;
                   esac
               done

               if [[ -z "$dst" ]]; then
                   echo "state.single file.managed 에 name= 값이 없습니다."
                   exit 1
               fi

               if [[ -z "$src" ]]; then
                   echo "state.single file.managed 에 source= 값이 없습니다."
                   exit 1
               fi

               if [[ "$src" != salt://* ]]; then
                   echo "현재 검증은 salt:// source 만 지원합니다: $src"
                   exit 1
               fi

               # salt:// source를 실제 Master 파일 경로로 변환 후 검증
               src_file=$(salt_source_to_file "$src")

               if [[ ! -f "$src_file" ]]; then
                   echo "source 파일 없음: $src_file"
                   exit 1
               fi

               if [[ ! -s "$src_file" ]]; then
                   echo "source 파일이 비어있습니다: $src_file"
                   exit 1
               fi

               # file.managed 실행 예정 내용을 SLS 형태로 출력
               echo
               echo "============================================================"
               echo "state.single file.managed 모드"
                echo "============================================================"
                echo "file.managed:"
                echo "  - name: $dst"
                echo "  - source: $src"

                if [[ -n "$mode" ]]; then
                    echo "  - mode: '$mode'"
                fi

                if [[ -n "$user" ]]; then
                    echo "  - user: $user"
                fi

                if [[ -n "$group" ]]; then
                    echo "  - group: $group"
                fi

                if [[ -n "$makedirs" ]]; then
                    echo "  - makedirs: $makedirs"
                fi

                if [[ -n "$replace" ]]; then
                    echo "  - replace: $replace"
                fi

                #echo "------------------------------------------------------------"
            else
                # file.managed 외 state.single은 인자만 출력
                echo
                echo "============================================================"
                echo "state.single 모드"
                echo "============================================================"
                printf '%s\n' "${SALT_ARGS[@]}"
                #echo "------------------------------------------------------------"
            fi

            echo
            ;;

        *)
            echo "지원하지 않는 SALT_FUNCTION 입니다: $SALT_FUNCTION"
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
    #   result/<host> = stdout 만 저장
    #   stdout 이 없으면 빈 파일 생성
    #
    #   error/<host> = stderr 만 저장
    #   stderr 없이 실패한 경우 comment 저장
    #   stderr/comment 모두 없으면 no_stderr 저장
    #
    #   성공 comment 는 저장하지 않는다.
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
# Salt 실행 전에 master 로컬에서 먼저 실행할 작업을 수행한다.
#
# 사용 예:
#   - rsync로 파일 사전 배포
#   - control 스크립트 실행
#   - 최종 server 파일 기준의 로컬 루프 작업
#
# 주의:
#   - local 실패 시 전체 작업도 실패 처리한다.
#   - 실행 기준 변수는 기존 프레임워크 변수 그대로 사용한다.
#     base_dir, home_dir, apply_dir, log_dir, tmp_dir 등
# ============================================================
run_user_local() {
    local local_file="$base_dir/local"
    if ! has_user_local; then
        return 0
    fi

    echo
    echo "============================================================"
    echo "local 실행"
    echo "============================================================"
    echo "파일: $local_file"
    echo "------------------------------------------------------------"

    (
        cd "$base_dir"
        . "$local_file"
    )

    #echo "------------------------------------------------------------"
}

# ============================================================
# sage 실행 히스토리 기록 #20260601 추가
# ============================================================
# sage로 Salt 작업을 실행할 때마다 전역 히스토리 로그를 남긴다.
#
# 기록 위치:
#   /var/log/salt/sage_history.log
#
# 기록 형식:
#   날짜시간    JOB: 작업경로    JID: Salt_JID    SALT_RC: Salt_결과코드
#
# 예:
#   2026-06-01 10:03:03    JOB: /data/salt/cron/backup/backup_mailbox_exec    JID: 20260601010303213293    SALT_RC: 0
#
# 주의:
#   - 히스토리 기록 실패가 Salt 작업 실패로 이어지면 안 되므로
#     마지막에 2>/dev/null || true 로 무시한다.
#   - ASYNC=true 인 경우 $log_dir/async_jid 에 저장된 JID를 사용한다.
#   - JID 파일이 없으면 no_jid 로 기록한다.
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

echo
echo "============================================================"
echo "대상 서버 목록 준비"
echo "============================================================"

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
        echo "▶ config에 server 파일 생성 로직이 있습니다."
        echo "------------------------------------------------------------"
        declare -f make_server | awk '
            /^[[:space:]]*#/ { next }
            /^[[:space:]]*$/ { next }
            { print }
        '
        echo "------------------------------------------------------------"
        echo "▶ 위 로직으로 server 실행 대상을 생성합니다."
        echo "▶ server 파일 생성중"

        # make_server 결과가 실제로 있는지 확인하기 위해 기존 server는 비우고 실행
        > "$base_dir/server"

        make_server
        if [[ ! -s "$base_dir/server" ]]; then
            echo "⚠ make_server 실행 결과 server 파일이 없거나 비어있습니다."

            if [[ -s "$server_backup" ]]; then
                cp -f "$server_backup" "$base_dir/server"
                echo "▶ 기존 server 파일을 사용합니다."
            else
                echo "⏹       $base_dir/server 파일이 없거나 비어있습니다."
                exit 1
            fi
        fi
    else
        echo "▶ config에 make_server 함수는 있지만 실제 server 생성 로직이 없습니다."

        if [[ ! -s "$base_dir/server" ]]; then
            echo "⏹       $base_dir/server 파일이 없거나 비어있습니다."
            exit 1
        fi

        echo "▶ 기존 server 파일을 사용합니다."
    fi
else
    echo "▶ config에 make_server 함수가 없습니다."

    if [[ ! -s "$base_dir/server" ]]; then
        echo "⏹       $base_dir/server 파일이 없거나 비어있습니다."
        exit 1
    fi

    echo "▶ 기존 server 파일을 사용합니다."
fi

# server_all 대신 server 파일을 기준으로 사용
awk 'NF {print $1}' "$base_dir/server" | sort -u > "$tmp_dir/server_target"

if [[ ! -s "$tmp_dir/server_target" ]]; then
    echo "⏹       server 대상 목록이 비어있습니다."
    exit 1
fi

# ============================================================
# Salt에 등록된 accepted minion 목록 생성
# ============================================================
echo
echo "============================================================"
echo "Salt minion 상태 검사"
echo "============================================================"
echo "▶ key 검사중"

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
        echo "▶ ping 검사 생략"
        #echo "▶ salt-key accepted 서버를 최종 실행 대상으로 사용합니다."

        # ping 검사를 생략하므로 registered 서버 전체를 ping_ok로 간주
        cp -f "$tmp_dir/server_registered" "$tmp_dir/server_ping_ok"

        # ping 검사를 생략하므로 ping_fail은 없음
        > "$tmp_dir/server_fail_not_ping"
        ;;

    false|FALSE|False|0|no|NO|No|n|N|"")
        echo "▶ ping 검사중"

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

echo "▶ Salt minion 상태 검사 완료"

if [[ ! -s "$base_dir/server" ]]; then
    echo "최종 실행 가능한 서버가 없습니다."
    echo "제외 서버 목록: $log_dir/server_fail"
    exit 1
fi

# ============================================================
# 실행 대상/제외 대상 정보 출력
# ============================================================
server_list=$(paste -sd, "$base_dir/server")
server_count=$(wc -l < "$base_dir/server")
skip_count=$(wc -l < "$log_dir/server_fail")

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

echo
echo "============================================================"
echo "최종 실행 대상 서버"
echo "============================================================"
paste -sd, "$base_dir/server"
echo "------------------------------------------------------------"
echo "서버 개수: $server_count"
echo "------------------------------------------------------------"
echo
if (( skip_count > 0 )); then
    echo
    echo "============================================================"
    echo "제외 서버 목록"
    echo "============================================================"
    awk '{print $1 "(" $2 ")"}' "$log_dir/server_fail" | paste -sd,
    echo "------------------------------------------------------------"
    echo "제외 서버 수: $skip_count"
    echo "------------------------------------------------------------"
    echo
fi

if (( server_count == 0 )); then
    echo "⏹        실행 대상 없음"
    exit 1
fi
# ============================================================
# local 사용 모드 출력
# ============================================================
echo
echo "============================================================"
echo "local 사용 모드"
echo "============================================================"
echo "파일: $base_dir/local"
echo "------------------------------------------------------------"

if has_user_local; then
    echo "▶ local=true"
    echo "salt-run 실행 전에 master 로컬에서 local 스크립트를 실행합니다."
else
    echo "▶ local=false"
    echo "local 파일이 없거나 주석/공백만 있어 실행하지 않습니다."
fi

#echo "------------------------------------------------------------"

# 실행 전 작업 내용 검증 및 출력
validate_and_preview_job

echo "============================================================"
echo "실행 모드"
echo "============================================================"
case "${ASYNC:-false}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y)
        echo "▶ ASYNC=true"
        echo "Salt job만 등록하고 결과는 기다리지 않습니다."

        if [[ "${ASYNC_RESULT_MODE:-0}" -eq 1 ]]; then
            echo "▶ ASYNC_RESULT=true"
            echo "remote stdout/stderr/exit code를 event로 수집합니다."
            echo "result/error 생성과 post 실행은 listener가 처리합니다."
        else
            echo "▶ ASYNC_RESULT=false"
            echo "result/error 생성과 post 스크립트는 실행하지 않습니다."
        fi
        ;;
    *)
        echo "▶ ASYNC=false"
        echo "Salt 결과를 기다린 뒤 result/error를 생성하고 post를 실행합니다."

        case "${COLLECT_BY_JID:-true}" in
            true|TRUE|True|1|yes|YES|Yes|y|Y)
                echo "▶ COLLECT_BY_JID=true"
                echo "JID 기반으로 진행률을 확인하고 마지막에 결과를 수집합니다."

                if [[ -n "${JID_CHUNK_SIZE:-}" ]]; then
                    echo ""
					echo "▶ JID_CHUNK_SIZE=$JID_CHUNK_SIZE"
                    echo "전체 대상 수: $server_count"
                    echo "총 실행 횟수: $jid_chunk_count"
                    #echo "------------------------------------------------------------"

                    chunk_no=1
                    chunk_start=1
                    while (( chunk_no <= jid_chunk_count )); do
                        chunk_end=$(( chunk_start + JID_CHUNK_SIZE - 1 ))
                        if (( chunk_end > server_count )); then
                            chunk_end=$server_count
                        fi

                        chunk_targets=$(( chunk_end - chunk_start + 1 ))
                        echo "${chunk_no}/${jid_chunk_count} : ${chunk_targets}대"

                        chunk_start=$(( chunk_end + 1 ))
                        chunk_no=$(( chunk_no + 1 ))
                    done
                fi
                ;;
            *)
                echo "▶ COLLECT_BY_JID=false"
                echo "기존 방식처럼 Salt stdout을 log_salt에 기록하며 진행률을 계산합니다."
                ;;
        esac
        ;;
esac
#echo "------------------------------------------------------------"
echo

echo "============================================================"
echo "post 사용 모드"
echo "============================================================"
case "${ASYNC:-false}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y)
        if [[ "${ASYNC_RESULT_MODE:-0}" -eq 1 ]] && post_has_effective_content "$base_dir/post"; then
            echo "파일: $base_dir/post"
            echo "------------------------------------------------------------"
            echo "▶ post=true"
            echo "ASYNC_RESULT 완료 event로 result/error가 모두 생성되면 post 스크립트를 1회 실행합니다."
        else
            echo "▶ post=false"

            if [[ "${ASYNC_RESULT_MODE:-0}" -eq 1 ]]; then
                echo "post 파일이 없거나 주석/공백만 있어 실행하지 않습니다."
            else
                echo "ASYNC=true, ASYNC_RESULT=false 이므로 result/error 생성과 post 스크립트 실행을 생략합니다."
            fi
        fi
        ;;
    *)
        if post_has_effective_content "$base_dir/post"; then
			echo "파일: $base_dir/post"
			echo "------------------------------------------------------------"
            echo "▶ post=true"
            echo "salt-run 완료 후 사용자 post 스크립트를 실행합니다."
        else
            echo "▶ post=false"
            echo "post 파일이 없거나 주석/공백만 있어 실행하지 않습니다."
        fi
        ;;
esac
echo "------------------------------------------------------------"
echo

# ============================================================
# 사용자 실행 확인
# -y 옵션이 있으면 자동 yes 처리
# ============================================================
if [[ $AUTO_YES -eq 1 ]]; then
    answer="y"
else
    read -r -p "▶ 이 서버들에 대해 실행하시겠습니까? (Y/n): " answer
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
                    #echo "------------------------------------------------------------"
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

