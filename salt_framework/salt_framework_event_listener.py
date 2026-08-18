#!/usr/bin/env python3
import fcntl
import fnmatch
import os
import socket
import subprocess
import time

import salt.config
import salt.utils.event


MASTER_CONFIG = "/etc/salt/master"
EVENT_TAG_PATTERN = "salt/framework/async/*"
LOG_FILE = "/var/log/salt/framework_event_listener.log"


TRUE_VALUES = {
    "1",
    "true",
    "TRUE",
    "True",
    "yes",
    "YES",
    "Yes",
    "y",
    "Y",
}


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


def get_local_master_ips():
    ips = []

    for _ in range(3):
        try:
            proc = subprocess.run(
                ["hostname", "-I"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
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


def is_safe_base_dir(base_dir):
    try:
        real_base_dir = os.path.realpath(base_dir)
    except Exception:
        return False

    allowed_prefixes = (
        "/data/salt/manual/",
        "/data/salt/cron/",
        "/data/salt/shared/",
    )

    return any(real_base_dir.startswith(prefix) for prefix in allowed_prefixes)


def is_safe_minion_id(minion_id):
    if not minion_id:
        return False

    if minion_id in (".", ".."):
        return False

    if "/" in minion_id or "\\" in minion_id:
        return False

    return True


def is_safe_run_id(run_id):
    if not run_id or len(run_id) > 128:
        return False

    if run_id in (".", ".."):
        return False

    if "/" in run_id or "\\" in run_id:
        return False

    return all(ch.isalnum() or ch in "._-" for ch in run_id)


def write_text_file(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)

    if content is None:
        content = ""

    content = str(content).rstrip()

    with open(path, "w", encoding="utf-8") as f:
        if content:
            f.write(content + "\n")
        else:
            f.write("")


def append_text_file(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)

    if content is None:
        content = ""

    content = str(content).rstrip()
    exists_with_content = os.path.exists(path) and os.path.getsize(path) > 0

    with open(path, "a", encoding="utf-8") as f:
        if exists_with_content and content:
            f.write("\n")

        if content:
            f.write(content + "\n")


def post_has_effective_content(post_file):
    if not os.path.isfile(post_file):
        return False

    try:
        with open(post_file, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                stripped = line.strip()
                if stripped and not stripped.startswith("#"):
                    return True
    except Exception:
        return False

    return False


def parse_async_pending_line(line):
    parts = line.rstrip("\n").split("\t")

    if len(parts) != 4:
        return None

    pending_run_id = parts[0].strip()
    hosts_raw = parts[1].strip()
    keep_tmp_raw = parts[2].strip()
    jid = parts[3].strip()

    expected_hosts = []
    seen = set()

    for host in hosts_raw.split(","):
        host = host.strip()

        if host and host not in seen:
            seen.add(host)
            expected_hosts.append(host)

    if not pending_run_id or not expected_hosts or not jid.isdigit():
        return None

    keep_tmp = keep_tmp_raw in TRUE_VALUES

    return pending_run_id, expected_hosts, keep_tmp, jid


def get_done_hosts(result_status_file):
    done = set()

    try:
        with open(result_status_file, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")

                if len(parts) < 2:
                    continue

                host = parts[0].strip()
                status = parts[1].strip()

                if host and status == "async_done":
                    done.add(host)
    except Exception:
        pass

    return done


def mark_done_host(result_status_file, minion_id, ended_epoch):
    done_hosts = get_done_hosts(result_status_file)

    if minion_id in done_hosts:
        return

    with open(result_status_file, "a", encoding="utf-8") as f:
        f.write(f"{minion_id}\tasync_done\t{ended_epoch}\n")
        f.flush()
        os.fsync(f.fileno())


def get_async_last_ended_epoch(result_status_file):
    last_ended_epoch = 0

    try:
        with open(result_status_file, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")

                if len(parts) < 3 or parts[1].strip() != "async_done":
                    continue

                try:
                    ended_epoch = int(parts[2].strip())
                except Exception:
                    continue

                if ended_epoch > last_ended_epoch:
                    last_ended_epoch = ended_epoch
    except Exception:
        pass

    return last_ended_epoch


def format_kst_epoch(epoch):
    try:
        epoch = int(epoch)
    except Exception:
        epoch = 0

    if epoch <= 0:
        return time.strftime("%Y-%m-%d %H:%M:%S")

    return time.strftime(
        "%Y-%m-%d %H:%M:%S",
        time.gmtime(epoch + (9 * 60 * 60)),
    )


def append_async_jid_history_final(
    base_dir,
    jid,
    target_count,
    final_rc,
    history_time,
):
    history_dir = "/var/log/salt"
    history_log = os.path.join(history_dir, "sage_history.log")
    history_lock = history_log + ".lock"

    if not str(jid).isdigit():
        return False

    try:
        os.makedirs(history_dir, exist_ok=True)

        with open(history_lock, "a+", encoding="utf-8") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)

            if os.path.exists(history_log):
                with open(
                    history_log,
                    "r",
                    encoding="utf-8",
                    errors="replace",
                ) as f:
                    for line in f:
                        fields = line.rstrip("\n").split("\t")

                        has_jid = any(
                            field == f"JID: {jid}"
                            for field in fields
                        )
                        has_rc = any(
                            field.startswith("SALT_RC:")
                            for field in fields
                        )

                        if has_jid and has_rc:
                            return True

            with open(history_log, "a", encoding="utf-8") as f:
                f.write(
                    f"{history_time}\t"
                    f"JOB: {base_dir}\t"
                    f"TYPE: MAIN\t"
                    f"LABEL: -\t"
                    f"JID: {jid}\t"
                    f"TARGETS: {target_count}\t"
                    f"SALT_RC: {final_rc}\n"
                )
                f.flush()
                os.fsync(f.fileno())

        return True

    except Exception as e:
        log(
            f"history_final_failed base_dir={base_dir} jid={jid} "
            f"rc={final_rc} error={e}"
        )
        return False


def run_post_once(base_dir, run_id):
    log_dir = os.path.join(base_dir, "log")
    post_file = os.path.join(base_dir, "post")

    if not post_has_effective_content(post_file):
        log(
            f"post_skip reason=no_effective_post "
            f"base_dir={base_dir} run_id={run_id}"
        )
        return

    env = os.environ.copy()
    env.update(
        {
            "home_dir": "/data/salt",
            "base_dir": base_dir,
            "log_dir": log_dir,
            "result_dir": os.path.join(base_dir, "result"),
            "error_dir": os.path.join(base_dir, "error"),
            "tmp_dir": os.path.join(base_dir, ".tmp"),
            "FRAMEWORK_RUN_ID": run_id,
        }
    )

    log(f"post_start base_dir={base_dir} run_id={run_id}")

    try:
        proc = subprocess.run(
            ["bash", "-c", ". \"$1\"", "salt_framework_post", post_file],
            cwd=base_dir,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=3600,
        )

        rc = proc.returncode
        stdout = proc.stdout.strip().replace("\n", "\\n")
        stderr = proc.stderr.strip().replace("\n", "\\n")

        log(
            f"post_done base_dir={base_dir} run_id={run_id} "
            f"rc={rc} stdout={stdout} stderr={stderr}"
        )

    except subprocess.TimeoutExpired:
        log(
            f"post_done base_dir={base_dir} run_id={run_id} "
            f"rc=124 error=post_timeout"
        )

    except Exception as e:
        log(
            f"post_done base_dir={base_dir} run_id={run_id} "
            f"rc=1 error={e}"
        )


def all_async_hosts_done(expected_hosts, result_status_file):
    expected_set = set(expected_hosts)
    done_hosts = get_done_hosts(result_status_file)
    missing_hosts = sorted(expected_set - done_hosts)

    if missing_hosts:
        log(
            f"async_wait missing_count={len(missing_hosts)} "
            f"missing={','.join(missing_hosts)}"
        )
        return False

    return True


def cleanup_async_tmp(base_dir, result_status_file, keep_tmp):
    tmp_dir = os.path.join(base_dir, ".tmp")

    if keep_tmp:
        log(f"async_tmp_keep reason=keep_tmp base_dir={base_dir}")
        return

    try:
        if os.path.exists(result_status_file):
            os.remove(result_status_file)
    except Exception as e:
        log(
            f"async_tmp_cleanup_failed "
            f"base_dir={base_dir} "
            f"path={result_status_file} "
            f"error={e}"
        )
        return

    try:
        os.rmdir(tmp_dir)
        log(f"async_tmp_removed base_dir={base_dir}")
    except FileNotFoundError:
        pass
    except OSError as e:
        log(
            f"async_tmp_cleanup_deferred "
            f"base_dir={base_dir} "
            f"path={tmp_dir} "
            f"error={e}"
        )


def handle_async_done(payload):
    run_id = str(payload.get("run_id", "")).strip()
    base_dir = str(payload.get("base_dir", "")).strip()
    minion_id = str(payload.get("minion_id", "")).strip()
    status = str(payload.get("status", "unknown"))
    exit_code_raw = payload.get("exit_code", 1)
    ended_epoch_raw = payload.get("ended_epoch", 0)

    stdout_content = payload.get("stdout_content", None)
    if stdout_content is None:
        stdout_content = payload.get("result_content", "")

    stderr_content = payload.get("stderr_content", "")

    stdout_content = "" if stdout_content is None else str(stdout_content).rstrip()
    stderr_content = "" if stderr_content is None else str(stderr_content).rstrip()

    try:
        exit_code = int(exit_code_raw)
    except Exception:
        exit_code = 1

    try:
        ended_epoch = int(ended_epoch_raw)
    except Exception:
        ended_epoch = 0

    if not is_safe_base_dir(base_dir):
        log(
            f"async_done_skip reason=invalid_base_dir "
            f"base_dir={base_dir} run_id={run_id} minion={minion_id}"
        )
        return

    if not is_safe_run_id(run_id):
        log(
            f"async_done_skip reason=invalid_run_id "
            f"base_dir={base_dir} run_id={run_id} minion={minion_id}"
        )
        return

    if not is_safe_minion_id(minion_id):
        log(
            f"async_done_skip reason=invalid_minion_id "
            f"base_dir={base_dir} run_id={run_id} minion={minion_id}"
        )
        return

    tmp_dir = os.path.join(base_dir, ".tmp")
    pending_file = os.path.join(tmp_dir, "async_pending")
    result_status_file = os.path.join(tmp_dir, "result_status")
    cancel_marker = os.path.join(tmp_dir, "cancelled")
    jid_registering_file = os.path.join(tmp_dir, "jid_registering")

    # async_pending은 Salt submit 전에 생성될 수 있으므로 JID registry 기록이
    # 끝나기 전에 event가 도착하면 jid_registering marker가 사라질 때까지 기다린다.
    for _ in range(100):
        if not os.path.exists(jid_registering_file):
            break

        time.sleep(0.1)

    if os.path.exists(jid_registering_file):
        log(
            f"async_done_skip reason=jid_registering "
            f"base_dir={base_dir} run_id={run_id} minion={minion_id}"
        )
        return

    if os.path.exists(cancel_marker):
        log(
            f"async_done_skip reason=cancelled "
            f"base_dir={base_dir} run_id={run_id} minion={minion_id}"
        )
        return

    if not os.path.isfile(pending_file):
        log(
            f"async_done_skip reason=no_async_pending "
            f"base_dir={base_dir} run_id={run_id} minion={minion_id}"
        )
        return

    async_complete = False
    keep_tmp = False

    try:
        with open(pending_file, "r+", encoding="utf-8") as pending_lock:
            fcntl.flock(pending_lock.fileno(), fcntl.LOCK_EX)

            # lock을 기다리는 동안 다른 listener가 전체 완료 처리를 끝내고
            # async_pending path를 제거했으면 중복 event이므로 종료한다.
            if not os.path.exists(pending_file):
                return

            pending_lock.seek(0)
            pending = parse_async_pending_line(pending_lock.readline())

            if pending is None:
                log(
                    f"async_done_skip reason=invalid_async_pending "
                    f"base_dir={base_dir} run_id={run_id} minion={minion_id}"
                )
                return

            pending_run_id, expected_hosts, keep_tmp, pending_jid = pending

            if pending_run_id != run_id:
                log(
                    f"async_done_skip reason=run_id_mismatch "
                    f"base_dir={base_dir} "
                    f"event_run_id={run_id} "
                    f"pending_run_id={pending_run_id} "
                    f"minion={minion_id}"
                )
                return

            if minion_id not in set(expected_hosts):
                log(
                    f"async_done_skip reason=unexpected_minion "
                    f"base_dir={base_dir} run_id={run_id} minion={minion_id}"
                )
                return

            if os.path.exists(cancel_marker) or not os.path.exists(pending_file):
                log(
                    f"async_done_skip reason=cancelled_or_pending_removed "
                    f"base_dir={base_dir} run_id={run_id} minion={minion_id}"
                )
                return

            if minion_id in get_done_hosts(result_status_file):
                log(
                    f"async_done_skip reason=already_done "
                    f"base_dir={base_dir} run_id={run_id} minion={minion_id}"
                )
                return

            result_dir = os.path.join(base_dir, "result")
            error_dir = os.path.join(base_dir, "error")
            result_file = os.path.join(result_dir, minion_id)
            error_file = os.path.join(error_dir, minion_id)

            os.makedirs(result_dir, exist_ok=True)
            os.makedirs(error_dir, exist_ok=True)

            wrote_result = False
            wrote_error = False
            is_failed = exit_code != 0 or status != "success"

            # ============================================================
            # 저장 정책
            # ============================================================
            # 1. stderr가 있으면:
            #    - stdout은 result에 저장
            #    - stderr는 error에 저장
            #
            # 2. stderr가 없고 실패이면:
            #    - stdout이 있으면 error에만 저장
            #    - stdout도 없으면 빈 error 파일 생성
            #
            # 3. 성공이면:
            #    - stdout을 result에 저장
            #    - stdout이 없어도 빈 result 파일 생성
            #    - local의 file_deploy가 남긴 기존 error 파일은 유지
            # ============================================================
            if stderr_content:
                if stdout_content:
                    write_text_file(result_file, stdout_content)
                    wrote_result = True

                append_text_file(error_file, stderr_content)
                wrote_error = True

            elif is_failed:
                if stdout_content:
                    append_text_file(error_file, stdout_content)
                else:
                    append_text_file(error_file, "")

                wrote_error = True

                try:
                    if os.path.exists(result_file):
                        os.remove(result_file)
                except Exception:
                    pass

            else:
                write_text_file(result_file, stdout_content)
                wrote_result = True

            log(
                f"async_result_written base_dir={base_dir} run_id={run_id} "
                f"minion={minion_id} rc={exit_code} "
                f"result={'yes' if wrote_result else 'no'} "
                f"error={'yes' if wrote_error else 'no'}"
            )

            # 결과 저장 중 Ctrl+C/TERM이 들어와 start.sh가 async_pending을
            # 제거했으면 완료 marker와 post를 진행하지 않는다.
            if os.path.exists(cancel_marker) or not os.path.exists(pending_file):
                log(
                    f"async_done_skip reason=cancelled_or_pending_removed "
                    f"base_dir={base_dir} run_id={run_id} minion={minion_id}"
                )
                return

            mark_done_host(
                result_status_file,
                minion_id,
                ended_epoch,
            )

            if not all_async_hosts_done(expected_hosts, result_status_file):
                return

            # 마지막 host 완료 판정 후 history/post 처리 직전
            # 취소 상태를 다시 확인한다.
            if os.path.exists(cancel_marker) or not os.path.exists(pending_file):
                log(
                    f"post_skip reason=cancelled_or_pending_removed "
                    f"base_dir={base_dir} run_id={run_id} minion={minion_id}"
                )
                return

            # 모든 대상 event가 정상 수집된 경우,
            # 가장 마지막으로 종료된 minion의 실제 종료시각을 기준으로
            # 해당 JID의 FINAL SALT_RC=0 history를 기록한다.
            last_ended_epoch = get_async_last_ended_epoch(
                result_status_file
            )

            completed_at = format_kst_epoch(
                last_ended_epoch
            )

            append_async_jid_history_final(
                base_dir,
                pending_jid,
                len(expected_hosts),
                0,
                completed_at,
            )

            run_post_once(base_dir, run_id)

            # async_pending 자체가 post 중복 실행 방지 marker다.
            # lock을 가진 listener가 post를 끝낸 뒤 path를 제거한다.
            try:
                os.remove(pending_file)
            except FileNotFoundError:
                pass

            async_complete = True

    except FileNotFoundError:
        return

    except Exception as e:
        log(
            f"async_done_state_error "
            f"base_dir={base_dir} run_id={run_id} "
            f"minion={minion_id} error={e}"
        )
        return

    if async_complete:
        cleanup_async_tmp(
            base_dir,
            result_status_file,
            keep_tmp,
        )


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
        event_master = str(payload.get("event_master", "")).strip()

        if event_master and local_master_ips and event_master not in local_master_ips:
            log(
                f"event_skip reason=event_master_mismatch "
                f"event_master={event_master} "
                f"local_master_ips={','.join(local_master_ips)} "
                f"tag={tag} run_id={run_id} minion={minion_id}"
            )
            continue

        if str(payload.get("event_type", "")).strip() == "async_done":
            handle_async_done(payload)
            continue

        log(
            f"event_skip reason=unsupported_event_type "
            f"tag={tag} run_id={run_id} minion={minion_id}"
        )


if __name__ == "__main__":
    main()

