# sage

`sage`는 `/data/salt` 아래 작업 디렉토리의 `config`, `pre`, `server`, `remote`, `local`, `post` 파일을 기준으로 Salt 작업을 실행하고 결과를 `result/`, `error/`, `log/`에 정리하는 Bash 기반 실행 래퍼입니다.

## 구성 파일

```text
/data/salt/common/salt_framework/
  sage
  start.sh
  salt_apply
  salt_framework_event_notify.sh
  salt_framework_event_listener.py

/data/salt/common/netbox_inventory/
  refresh_inventory.sh
  function
  pillar_make.sh
  accepted_nodes_sync.sh

/data/salt/common/sample/
  README
  config
  pre
  local
  remote
  post

/data/salt/{manual,shared,cron}/<분류>/<작업명>/
  config
  pre
  server
  remote
  local
  post
```

- `salt_framework/sage`: `/data/salt/common/salt_framework/start.sh`를 실행하는 launcher입니다.
- `salt_framework/start.sh`: 작업 디렉토리 결정, `config` 로드, 대상 서버 준비, 실행 전 검증을 담당합니다.
- `salt_framework/salt_apply`: 실제 Salt 실행, JID 수집, 결과 분류를 담당합니다.
- `salt_framework/salt_framework_event_notify.sh`: `ASYNC_RESULT=true`일 때 minion에서 실행 결과 event를 전송합니다.
- `salt_framework/salt_framework_event_listener.py`: master event bus를 감시해 async 결과를 `result/`, `error/`로 저장하고 `.tmp/result_status` 기준으로 전체 완료 시 `post`를 실행합니다.
- `netbox_inventory/refresh_inventory.sh`: NetBox에서 VM/Device inventory를 갱신하고 pillar 및 accepted key cache 갱신 스크립트를 실행합니다.
- `netbox_inventory/function`: NetBox inventory 기준으로 자주 쓰는 서버 목록 조회 함수를 제공합니다.
- `netbox_inventory/pillar_make.sh`: `vm_inventory` 기준으로 `/srv/pillar`의 minion pillar 파일을 생성합니다.
- `netbox_inventory/accepted_nodes_sync.sh`: `salt-key -l accepted` 결과를 `salt_framework/__cache__/accepted_nodes`로 갱신합니다.
- `sample/`: `sage -i`에서 복사하는 신규 작업 기본 샘플입니다.

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
| `-j`, `--jid [JID\|all]` | 실행 중인 Sage/Salt JID 상태를 조회합니다. |
| `-K`, `--kill-jid [JID]` | 실행 중인 Sage JID 또는 지정 JID를 중단합니다. |
| `-h`, `--help` | 사용법을 출력합니다. |

JID 조회:

```bash
# 현재 작업 경로의 실행 중 Sage JID 조회
sage -j

# 특정 JID 상태 조회
sage -j 20260818010101000000

# master 전체 실행 중 Salt JID 조회
sage -j all
```

JID 중단:

```bash
# 현재 작업 경로의 실행 중 Sage JID 중단
sage -K

# 특정 JID 중단
sage -K 20260818010101000000
```

`-j`, `-K`는 일반 실행 옵션이나 작업 경로와 같이 사용할 수 없습니다. `-K all`은 지원하지 않습니다.

## 작업 디렉토리 파일

| 파일 | 필수 | 설명 |
| --- | --- | --- |
| `config` | 예 | Salt 실행 설정을 Bash 변수로 정의합니다. |
| `pre` | 아니오 | `config` 로드 후, 대상 서버 확정 전에 master 로컬에서 실행할 사전 스크립트입니다. `server` 파일을 동적으로 생성할 때 사용합니다. |
| `server` | 조건부 | 실행 대상 서버 목록입니다. `pre`가 `server`를 생성하면 없어도 됩니다. |
| `remote` | 조건부 | `cmd.run + RUN_SCRIPT` 모드에서 대상 서버에서 실행할 스크립트입니다. |
| `local` | 아니오 | Salt 실행 전에 master 로컬에서 실행할 스크립트입니다. 주석/공백만 있으면 무시합니다. `file_deploy` 함수를 사용할 수 있습니다. |
| `post` | 아니오 | 결과 생성 후 master 로컬에서 실행할 후처리 스크립트입니다. 주석/공백만 있으면 무시합니다. |

`server` 파일은 한 줄에 host 하나를 권장합니다. 빈 줄과 `#` 주석은 일부 처리에서 무시됩니다.

`pre`는 별도 서브셸에서 실행되며, 상대경로와 `pwd`는 현재 작업 디렉토리(`$base_dir`) 기준으로 동작합니다. `pre`에서 변경한 변수, 함수, 작업 디렉토리는 Sage 본체에 영향을 주지 않습니다.

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

# JID_CHUNK_SIZE는 미설정 시 대상이 200대 초과하면 200이 자동 적용됩니다.
# 사용 시 기본값은 랜덤 셔플입니다.
# 정렬된 server 목록 순서대로 분할하려면 false로 설정합니다.
# JID_CHUNK_RANDOMIZE=false
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

대상 서버를 pre에서 생성:

```bash
#!/usr/bin/env bash

. /data/salt/common/netbox_inventory/function

inventory "select name from vm where zone = 'test-corp' and deploy_exception = 'false'" > "$base_dir/server"
```

## local file_deploy

`local` 파일 안에서는 `file_deploy`로 파일을 전체 대상 서버에 배포할 수 있습니다. 내부적으로 Salt `state.single file.managed`를 사용하며, 배포 실패는 `error/<host>`에 `deploy fail : <파일명>` 형식으로 기록합니다.

```bash
file_deploy $base_dir/files/app.tar.gz /home/
file_deploy $base_dir/files/app.conf /etc/app/app.conf
```

동작 기준:

- `local` 실행 중에만 사용할 수 있습니다.
- 대상 경로는 절대경로여야 합니다.
- 대상 경로가 `/`로 끝나면 원본 파일명을 유지합니다.
- 대상 경로에 `/.` 형태를 사용하면 정상 처리되지 않으므로 `/home/`처럼 디렉토리 경로를 그대로 지정해야 합니다.
- 배포용 source는 `/data/salt/apply/sage_file_deploy/<run_id>/` 아래에 임시 staging 후 종료 시 삭제합니다.
- 같은 파일시스템이면 hard link를 사용하고, 불가능하면 `cp -p`로 복사합니다.
- 배포 실패가 있어도 `server` 목록은 유지하고 이후 remote/Salt 실행은 계속 진행합니다.

파일 크기별 배포 chunk:

| 파일 크기 | chunk |
| --- | ---: |
| 1MB 이하 | 200 |
| 10MB 이하 | 100 |
| 100MB 이하 | 30 |
| 500MB 이하 | 10 |
| 1GB 이하 | 5 |
| 5GB 이하 | 2 |
| 5GB 초과 | 1 |

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
| `pre` | 없음 | `$base_dir/pre` 파일에 유효한 실행 내용이 있으면 실행 전에 별도 서브셸에서 실행합니다. 결과로 `$base_dir/server`가 생성되면 해당 목록을 사용하고, 비어 있으면 실행 전 기존 `server`를 사용합니다. |
| `SKIP_PING` | `false` | `true`이면 `test.ping` 검사를 생략하고 accepted key cache에 있는 서버를 실행 대상으로 사용합니다. |
| `DIRTY_NODES_FILE` | `/data/salt/common/dirty_nodes` | 실행에서 제외할 host 목록 파일입니다. 제외 사유는 `log/server_fail`에 `dirty_nodes`로 기록됩니다. |
| `KEY_FILE` | `$framework_dir/__cache__/accepted_nodes` | accepted key 목록 cache 파일입니다. `start.sh`는 `salt-key`를 직접 조회하지 않고 이 파일을 기준으로 등록 여부를 확인합니다. |

실행 모드 옵션:

| 옵션 | 기본값 | 설명 |
| --- | --- | --- |
| `ASYNC` | `false` | `true`이면 `salt --async`로 job만 등록하고 일반 결과 수집/post를 생략합니다. JID는 `log/jid_registry`에 기록합니다. |
| `COLLECT_BY_JID` | `true` | `ASYNC=false`일 때 JID 기반으로 진행률을 확인하고 마지막에 `jobs.lookup_jid` 결과를 수집합니다. `false`이면 기존 stdout 기반 수집을 사용합니다. |
| `ASYNC_RESULT` | `false` | `ASYNC=true + cmd.run + RUN_SCRIPT` 전용입니다. minion에서 stdout/stderr/exit code를 event로 보내고 listener가 결과를 저장합니다. |
| `JID_CHUNK_SIZE` | 미설정 | 미설정이면 대상이 200대 초과할 때 200이 자동 적용됩니다. 빈 값/0이면 자동 분할을 해제하고, 양의 정수이면 해당 개수 단위로 JID 기반 순차 실행합니다. `ASYNC=true` 또는 `COLLECT_BY_JID=false`와 같이 쓸 수 없습니다. |
| `JID_CHUNK_RANDOMIZE` | `true` | `JID_CHUNK_SIZE` 분할 전 대상 목록 랜덤 셔플 여부입니다. `false`이면 정렬된 최종 `server` 목록 순서대로 분할합니다. |
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
| `FILE_DEPLOY_WAIT_TIMEOUT` | `7200` | `file_deploy`에서 파일 배포 JID 결과를 기다리는 최대 시간입니다. |

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
| `log/jid_registry` | 현재 Sage 실행에서 발급된 `main`, `chunk`, `file_deploy` JID 추적 파일입니다. 취소 처리도 이 파일 기준으로 수행합니다. |
| `log/server_fail` | salt-key 미등록, ping 실패, dirty_nodes 제외 목록입니다. |
| `log/debug.log` | debug 모드 로그입니다. |
| `.tmp/async_pending` | `ASYNC_RESULT=true` 실행의 listener handoff 상태 파일입니다. `run_id`, 대상 host, `keep_tmp`, JID를 저장합니다. |
| `.tmp/result_status` | JID missing/timeout 분류 및 `ASYNC_RESULT` 완료 host 상태 파일입니다. ASYNC_RESULT에서는 host별 `ended_epoch`도 저장합니다. |
| `result/<host>` | host별 정상 stdout 결과입니다. stdout이 없어도 성공이면 빈 파일이 생성될 수 있습니다. |
| `error/<host>` | host별 stderr, 실패 stdout, `no_stderr`, timeout/미반환 분류 결과입니다. |

전역 이력:

| 경로 | 설명 |
| --- | --- |
| `/var/log/salt/sage_history.log` | Sage가 발급한 JID 이력입니다. JID 생성 시 CREATE 이력, 종료 시 FINAL 이력을 남깁니다. |

`sage_history.log`는 `MAIN`, `JID_CHUNK`, `FILE_DEPLOY` 유형을 구분합니다. 같은 JID는 CREATE 1회, FINAL 1회만 기록합니다. FINAL의 `SALT_RC`는 정상 완료 `0`, 실패 `1`, `Ctrl+C`/`sage -K` 중단 `130`, `TERM` 중단 `143` 기준입니다.

`ASYNC_RESULT=true`는 전체 async 결과 수집 완료 후 JID FINAL 기록, `post` 실행, `async_pending`/`.tmp` 정리 순서로 처리합니다. FINAL 시간은 전체 대상 중 가장 늦게 종료된 minion의 `ended_epoch` 기준입니다.

## 실행 취소

실행 중 `Ctrl+C` 또는 `TERM`을 받으면 현재 Sage 실행에서 발급된 JID를 `log/jid_registry` 기준으로 확인하고, 실행 중인 Salt job에 `saltutil.term_job` 후 필요 시 `saltutil.kill_job`을 시도합니다.

- `main`, `JID_CHUNK_SIZE` 청크, `file_deploy` 실행 JID가 모두 취소 대상입니다.
- 취소 요청 이후에는 새 Salt JID를 추가 제출하지 않습니다.
- JID 발급 직후 registry 기록 전 취소 누락을 막기 위해 짧은 보호구간을 둡니다.
- `file_deploy` 취소 중 종료 상태를 확인하지 못한 minion이 있으면 staging 경로를 삭제하지 않고 유지합니다.
- `sage -K`는 실제 `RUNNING` 상태를 확인한 뒤 `term_job`을 수행하고, 계속 실행 중이면 `kill_job` 후 다시 종료 상태를 확인합니다.
- 현재 작업의 `ASYNC_RESULT` pending JID를 `sage -K <JID>`로 중단하면 현재 작업 중단 흐름으로 처리해 `.tmp` 정리까지 수행합니다.

## async result listener

`ASYNC_RESULT=true`를 쓰려면 master에서 listener service가 실행 중이어야 합니다.

```bash
systemctl status salt-framework-event.service
```

listener는 `salt/framework/async/*` event를 감시합니다. payload의 `base_dir`이 `/data/salt/manual/`, `/data/salt/cron/`, `/data/salt/shared/` 아래가 아니면 무시합니다.

`ASYNC_RESULT=true` 실행은 `.tmp/async_pending`을 listener handoff marker로 사용합니다. listener는 `.tmp/result_status`에 host별 `async_done`과 `ended_epoch`를 기록하고, 전체 대상 event를 받은 뒤 `post`를 한 번만 실행합니다. 완료 후 `--keep-tmp`가 아니면 listener가 `.tmp` 상태 파일을 정리합니다.

minion의 async event 전송이 재시도 후에도 실패하면 `salt_framework_event_notify.sh`가 실패 rc를 반환합니다.

## NetBox inventory

`netbox_inventory/refresh_inventory.sh`는 NetBox API에서 VM/Device 정보를 조회해 아래 파일을 갱신합니다.

```text
/data/salt/common/netbox_inventory/vm_inventory
/data/salt/common/netbox_inventory/device_inventory
```

`vm_inventory`에는 name, role, zone, platform, service_unit, IP, site, cluster, vm_zone, backup, deploy exception, template 정보가 저장됩니다. `device_inventory`에는 name, role, platform, IP, site 정보가 저장됩니다.

inventory 갱신 후 아래 작업도 이어서 실행합니다.

```bash
bash /data/salt/common/netbox_inventory/pillar_make.sh
bash /data/salt/common/netbox_inventory/accepted_nodes_sync.sh
```

`accepted_nodes_sync.sh`는 `salt-key -l accepted` 조회 결과를 `/data/salt/common/salt_framework/__cache__/accepted_nodes`에 저장합니다. `start.sh`는 실행 때마다 `salt-key`를 직접 호출하지 않고 이 cache 파일로 accepted minion 여부를 확인합니다. cache 파일이 없거나 비어 있으면 실행을 중단합니다.

`function` 파일은 `pre`에서 source 해서 사용할 수 있습니다.

```bash
. /data/salt/common/netbox_inventory/function

# SQL-like 직접 조회
inventory "select name from vm where zone = 'test-corp' and deploy_exception = 'false'" > "$base_dir/server"

# 고정 함수 사용
get_allservers > "$base_dir/server"
get_valid_s_mailservers > "$base_dir/server"
get_valid_d_mailservers > "$base_dir/server"
get_valid_mailservers > "$base_dir/server"
```

주요 함수:

| 함수 | 설명 |
| --- | --- |
| `get_allservers` | VM + Device 전체 서버입니다. |
| `get_vm_allservers` | VM 전체 서버입니다. |
| `get_device_allservers` | 전체 Device 서버입니다. |
| `get_mailservers` | `service_unit=webmail_SVC` 전체 메일 서버입니다. |
| `get_valid_s_mailservers` | 통합 메일 서버입니다. |
| `get_valid_d_mailservers` | 단독 메일 서버입니다. |
| `get_valid_resellers` | 리셀러 전용 통합 메일 서버입니다. |
| `get_valid_mailservers` | `deploy_exception=false`인 전체 메일 서버입니다. |

## 의존 명령

- `bash`
- `python3`
- `salt`, `salt-run`, `salt-key`
- `jq`
- `flock`
- `setsid`
- `timeout` 또는 호환 명령: 없으면 일부 hard timeout만 비활성화됩니다.

## 주의사항

- `config`, `pre`, `local`, `post`는 Bash로 실행됩니다. 신뢰 가능한 작업 디렉토리에서만 사용하세요.
- `base_dir`, `home_dir`, `apply_dir`은 `start.sh`가 다시 고정합니다. config에서 같은 이름을 선언해도 실행 기준은 `start.sh`가 결정한 값입니다.
- accepted key 목록은 `salt_framework/__cache__/accepted_nodes` cache 파일 기준입니다. 최신화는 `netbox_inventory/accepted_nodes_sync.sh` 또는 `refresh_inventory.sh`로 수행합니다.
- `ASYNC=true` 단독 모드는 job만 등록하고 `result/`, `error/`, `post` 처리를 하지 않습니다.
- 실패 분류는 stderr를 우선합니다. stderr가 있으면 stdout은 `result/`, stderr는 `error/`에 저장됩니다.
- `file_deploy`가 먼저 만든 `error/<host>`는 이후 remote 결과 처리에서 삭제하지 않고 append 방식으로 유지합니다.
