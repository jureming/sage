# sage

`sage`는 `/data/salt` 아래 작업 디렉토리의 `config`, `server`, `remote`, `local`, `post` 파일을 기준으로 Salt 작업을 실행하고 결과를 `result/`, `error/`, `log/`에 정리하는 Bash 기반 실행 래퍼입니다.

## 구성 파일

```text
/data/salt/common/salt_framework/
  sage
  start.sh
  salt_apply

/data/salt/common/
  salt_framework_event_notify.sh
  salt_framework_event_listener.py

/data/salt/manual/<분류>/<작업명>/
  config
  server
  remote
  local
  post
```

- `salt_framework/sage`: `/data/salt/common/salt_framework/start.sh`를 실행하는 launcher입니다.
- `salt_framework/start.sh`: 작업 디렉토리 결정, `config` 로드, 대상 서버 준비, 실행 전 검증을 담당합니다.
- `salt_framework/salt_apply`: 실제 Salt 실행, JID 수집, 결과 분류를 담당합니다.
- `salt_framework_event_notify.sh`: `ASYNC_RESULT=true`일 때 minion에서 실행 결과 event를 전송합니다.
- `salt_framework_event_listener.py`: master event bus를 감시해 async 결과를 `result/`, `error/`로 저장하고 필요하면 `post`를 실행합니다.

## 실행 방법

작업 디렉토리에서 실행:

```bash
cd /data/salt/manual/owner/sample
sage
```

작업 경로를 직접 지정:

```bash
sage -y manual/owner/sample
sage -y /data/salt/manual/owner/sample
```

새 작업 생성:

```bash
cd /data/salt/manual/owner
sage -i sample
```

CLI 옵션:

| 옵션 | 설명 |
| --- | --- |
| `-y`, `--yes` | 실행 확인 질문 없이 바로 실행합니다. cron에서는 보통 이 옵션을 사용합니다. |
| `--keep-tmp` | 종료 후 `.tmp` 디렉토리를 삭제하지 않습니다. 디버깅용입니다. |
| `-d`, `--debug` | `log/debug.log` 기록과 터미널 debug 출력을 켭니다. |
| `-i`, `--init <작업경로>` | `/data/salt/common/sample`을 복사해 새 작업 디렉토리를 만듭니다. |
| `-h`, `--help` | 사용법을 출력합니다. |

## 작업 디렉토리 파일

| 파일 | 필수 | 설명 |
| --- | --- | --- |
| `config` | 예 | Salt 실행 설정을 Bash 변수로 정의합니다. |
| `server` | 조건부 | 실행 대상 서버 목록입니다. `make_server`가 `server`를 생성하면 없어도 됩니다. |
| `remote` | 조건부 | `cmd.run + RUN_SCRIPT` 모드에서 대상 서버에서 실행할 스크립트입니다. |
| `local` | 아니오 | Salt 실행 전에 master 로컬에서 실행할 스크립트입니다. 주석/공백만 있으면 무시합니다. |
| `post` | 아니오 | 결과 생성 후 master 로컬에서 실행할 후처리 스크립트입니다. 주석/공백만 있으면 무시합니다. |

`server` 파일은 한 줄에 host 하나를 권장합니다. 빈 줄과 `#` 주석은 일부 처리에서 무시됩니다.

## config 예시

remote 스크립트를 실행하고 결과를 JID로 수집하는 기본 예시:

```bash
SALT_FUNCTION="cmd.run"
SALT_ARGS=("__RUN_SCRIPT__")
RUN_SCRIPT="$base_dir/remote"

TIMEOUT=5
ASYNC=false
COLLECT_BY_JID=true
JOB_WAIT_TIMEOUT=300
```

SLS 실행 예시:

```bash
SALT_FUNCTION="state.apply"
SALT_ARGS=("sample")
TIMEOUT=10
```

단일 state 실행 예시:

```bash
SALT_FUNCTION="state.single"
SALT_ARGS=(
  "file.managed"
  "name=/tmp/sample.conf"
  "source=salt://sample/sample.conf"
  "mode=0644"
)
```

대상 서버를 config에서 생성:

```bash
make_server() {
    printf '%s\n' m10 m11 m12 > "$base_dir/server"
}
```

## config 옵션

필수 옵션:

| 옵션 | 설명 |
| --- | --- |
| `SALT_FUNCTION` | 실행할 Salt function입니다. 지원 값은 `state.apply`, `cmd.run`, `state.single`입니다. |
| `SALT_ARGS` | `SALT_FUNCTION`에 넘길 인자 배열입니다. 반드시 Bash 배열로 선언해야 합니다. |
| `RUN_SCRIPT` | `SALT_FUNCTION="cmd.run"` 및 `SALT_ARGS=("__RUN_SCRIPT__")`일 때 실행할 remote 파일 경로입니다. |

대상 생성/필터 옵션:

| 옵션 | 기본값 | 설명 |
| --- | --- | --- |
| `make_server()` | 없음 | 정의되어 있고 실제 로직이 있으면 실행 전에 `$base_dir/server`를 생성합니다. 결과가 비면 기존 `server`를 사용합니다. |
| `SKIP_PING` | `false` | `true`이면 `test.ping` 검사를 생략하고 salt-key accepted 서버를 실행 대상으로 사용합니다. |
| `DIRTY_NODES_FILE` | `/data/salt/common/dirty_nodes` | 실행에서 제외할 host 목록 파일입니다. 제외 사유는 `log/server_fail`에 `dirty_nodes`로 기록됩니다. |

실행 모드 옵션:

| 옵션 | 기본값 | 설명 |
| --- | --- | --- |
| `ASYNC` | `false` | `true`이면 `salt --async`로 job만 등록하고 일반 결과 수집/post를 생략합니다. JID는 `log/async_jid`에 저장합니다. |
| `COLLECT_BY_JID` | `true` | `ASYNC=false`일 때 JID 기반으로 진행률을 확인하고 마지막에 `jobs.lookup_jid` 결과를 수집합니다. `false`이면 기존 stdout 기반 수집을 사용합니다. |
| `ASYNC_RESULT` | `false` | `ASYNC=true + cmd.run + RUN_SCRIPT` 전용입니다. minion에서 stdout/stderr/exit code를 event로 보내고 listener가 결과를 저장합니다. |
| `JID_CHUNK_SIZE` | 비움 | 양의 정수이면 대상 서버를 해당 개수 단위로 나눠 JID 기반 순차 실행합니다. `ASYNC=true` 또는 `COLLECT_BY_JID=false`와 같이 쓸 수 없습니다. |
| `BATCH` | 비움 | `COLLECT_BY_JID=false`인 기존 stdout 수집 모드에서 Salt `-b` batch 옵션으로 사용됩니다. |

timeout/재시도 옵션:

| 옵션 | 기본값 | 설명 |
| --- | --- | --- |
| `TIMEOUT` | `3` | Salt `--timeout` 값입니다. 1 이상의 정수여야 합니다. ping 검사에도 사용됩니다. |
| `POLL_INTERVAL` | `3` | JID missing 상태를 다시 확인하는 간격입니다. |
| `JOB_WAIT_TIMEOUT` | `300` | JID 결과를 기다리는 최대 시간입니다. |
| `RUNNING_CHECK_INTERVAL` | `30` | missing 서버에 대해 `test.ping`/`saltutil.find_job` 상태 확인을 수행하는 간격입니다. |
| `LATE_CHECK_TIMEOUT` | `5` | missing 서버 상태 확인용 Salt timeout입니다. |
| `LATE_CHECK_HARD_TIMEOUT` | `15` | 상태 확인 명령 자체의 OS 레벨 hard timeout입니다. |
| `LOOKUP_HARD_TIMEOUT` | `30` | 중간 `jobs.lookup_jid` 조회의 hard timeout입니다. |
| `FINAL_LOOKUP_HARD_TIMEOUT` | `300` | 최종 `jobs.lookup_jid` 조회의 hard timeout입니다. |
| `PING_CHECK_PARALLEL` | `10` | missing 서버별 ping 확인 병렬 수입니다. |
| `PING_RETRY_COUNT` | `2` | host 단위 ping 재시도 횟수입니다. |
| `PING_RETRY_SLEEP` | `2` | ping 재시도 사이 대기 초입니다. |
| `JSON_PARSE_HARD_TIMEOUT` | `5` | JID missing JSON 파싱 hard timeout입니다. |

디버그/내부 경로 옵션:

| 옵션 | 기본값 | 설명 |
| --- | --- | --- |
| `DEBUG_MODE` | `false` | `true`이면 debug log를 기록합니다. `sage -d`가 자동으로 켭니다. |
| `DEBUG_PRINT` | `false` | `true`이면 debug log를 터미널에도 출력합니다. `sage -d`가 자동으로 켭니다. |
| `DEBUG_LOG` | `$base_dir/log/debug.log` | debug log 파일 경로입니다. |
| `RUN_LOCK_FILE` | `$base_dir/.run.lock` | 같은 작업 디렉토리 중복 실행 방지 lock 파일입니다. |
| `RESULT_STATUS_FILE` | `$base_dir/.tmp/result_status` | JID missing/timeout 분류 임시 상태 파일입니다. |
| `SALT_BIN` | `/usr/bin/salt` | Salt 실행 바이너리 경로입니다. 없으면 `command -v salt`로 찾습니다. |
| `SALT_RUN_BIN` | `/usr/bin/salt-run` | `salt-run` 바이너리 경로입니다. 없으면 `command -v salt-run`으로 찾습니다. |
| `TIMEOUT_BIN` | `command -v timeout` | hard timeout을 적용할 때 사용하는 `timeout` 바이너리입니다. |

ASYNC_RESULT/event 옵션:

| 옵션 | 기본값 | 설명 |
| --- | --- | --- |
| `EVENT_NOTIFY_LIB` | `$framework_dir/salt_framework_event_notify.sh` 또는 `/data/salt/common/salt_framework_event_notify.sh` | minion payload에 포함할 event 전송 함수 파일입니다. |
| `FRAMEWORK_EVENT_TAG` | `salt/framework/async/done` | async 완료 event tag입니다. |
| `FRAMEWORK_RUN_ID` | 실행 시각과 PID 기반 자동값 | async 결과 묶음 식별자입니다. |
| `FRAMEWORK_TASK_NAME` | 작업 디렉토리명 | async task 이름입니다. |
| `FRAMEWORK_EXEC_MASTER` | 실행 master hostname | async event를 처리할 master 식별자입니다. |
| `FRAMEWORK_EXEC_MASTER_IPS` | `hostname -I` 결과 | listener가 다른 master에서 온 event를 건너뛰는 데 사용합니다. |

## 결과 파일

| 경로 | 설명 |
| --- | --- |
| `log/log_salt` | Salt 실행 또는 최종 `jobs.lookup_jid` 결과 JSON 로그입니다. |
| `log/async_jid` | async/JID 실행에서 발급된 JID입니다. |
| `log/server_fail` | salt-key 미등록, ping 실패, dirty_nodes 제외 목록입니다. |
| `log/debug.log` | debug 모드 로그입니다. |
| `result/<host>` | host별 정상 stdout 결과입니다. stdout이 없어도 성공이면 빈 파일이 생성될 수 있습니다. |
| `error/<host>` | host별 stderr, 실패 stdout, `no_stderr`, timeout/미반환 분류 결과입니다. |

## async result listener

`ASYNC_RESULT=true`를 쓰려면 master에서 listener가 실행 중이어야 합니다.

```bash
python3 /data/salt/common/salt_framework_event_listener.py
```

listener는 `salt/framework/async/*` event를 감시합니다. payload의 `base_dir`이 `/data/salt/manual/`, `/data/salt/cron/`, `/data/salt/shared/` 아래가 아니면 무시합니다. 모든 대상 host의 `result/` 또는 `error/` 파일이 생성되면 `post`가 유효할 때 한 번만 실행합니다.

## 의존 명령

- `bash`
- `python3`
- `salt`, `salt-run`, `salt-key`
- `jq`
- `flock`
- `timeout` 또는 호환 명령: 없으면 일부 hard timeout만 비활성화됩니다.

## 주의사항

- `config`는 Bash로 `source`됩니다. 신뢰 가능한 작업 디렉토리에서만 사용하세요.
- `base_dir`, `home_dir`, `apply_dir`은 `start.sh`가 다시 고정합니다. config에서 같은 이름을 선언해도 실행 기준은 `start.sh`가 결정한 값입니다.
- `ASYNC=true` 단독 모드는 job만 등록하고 `result/`, `error/`, `post` 처리를 하지 않습니다.
- 실패 분류는 stderr를 우선합니다. stderr가 있으면 stdout은 `result/`, stderr는 `error/`에 저장됩니다.
