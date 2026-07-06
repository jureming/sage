#!/usr/bin/env bash
set -u
export LC_ALL=C

SLACK_COMMON_SCRIPT="/data/salt/common/send_to_slack"

slack_target="${1:-}"
title="${2:-Salt ASYNC 작업 완료}"
payload="${3:-}"

if [[ -z "$slack_target" ]]; then
    echo "slack target 없음. Slack 전송 생략"
    exit 0
fi

if [[ ! -f "$SLACK_COMMON_SCRIPT" ]]; then
    echo "send_to_slack 파일 없음: $SLACK_COMMON_SCRIPT" >&2
    exit 1
fi

# 기존 send_to_slack 안의 message_send, long_message_send, slack1~slackN 사용
# shellcheck disable=SC1090
source "$SLACK_COMMON_SCRIPT"

if [[ ! "$slack_target" =~ ^slack[0-9]+$ ]]; then
    echo "SLACK_TARGET 형식 오류: $slack_target" >&2
    echo "예: slack1, slack2, slack4, slack11" >&2
    exit 1
fi

if ! declare -p "$slack_target" >/dev/null 2>&1; then
    echo "send_to_slack 안에 ${slack_target} 변수가 없습니다." >&2
    exit 1
fi

webhook="${!slack_target}"

if [[ -z "$webhook" ]]; then
    echo "${slack_target} webhook 값이 비어있습니다." >&2
    exit 1
fi

message_send "$webhook" "$title" "$payload"
