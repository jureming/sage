#!/bin/bash

set -o pipefail

framework_dir="/data/salt/common/salt_framework"
cache_dir="$framework_dir/__cache__"
accepted_nodes_file="$cache_dir/accepted_nodes"
lock_dir="$cache_dir/.accepted_nodes.lock"

mkdir -p "$cache_dir"

# 실행 중인 프로세스가 있으면 종료
if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "accepted_nodes 갱신 작업이 이미 실행 중입니다." >&2
    exit 0
fi

tmp_file="$(mktemp "$cache_dir/.accepted_nodes.XXXXXX")"

cleanup() {
    rm -f "$tmp_file"
    rm -rf "$lock_dir"
}

trap cleanup EXIT INT TERM HUP

if ! timeout 30 salt-key -l accepted 2>/dev/null \
    | sed '1d;s/^[[:space:]]*//' \
    | awk 'NF' \
    | sort -u > "$tmp_file"; then

    echo "accepted_nodes 생성 실패: salt-key 조회 오류" >&2
    exit 1
fi

if [[ ! -s "$tmp_file" ]]; then
    echo "accepted_nodes 생성 실패: accepted key 목록이 비어 있음" >&2
    exit 1
fi

chmod 0644 "$tmp_file"
mv -f "$tmp_file" "$accepted_nodes_file"

exit 0
