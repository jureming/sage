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


def get_expected_hosts(base_dir):
    server_file = os.path.join(base_dir, "server")
    hosts = []
    seen = set()

    try:
        with open(server_file, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue

                host = stripped.split()[0]
                if host and host not in seen:
                    seen.add(host)
                    hosts.append(host)
    except Exception:
        return []

    return hosts


def get_done_hosts(base_dir):
    done = set()

    for dirname in ("result", "error"):
        path = os.path.join(base_dir, dirname)
        try:
            for name in os.listdir(path):
                full_path = os.path.join(path, name)
                if os.path.isfile(full_path):
                    done.add(name)
        except Exception:
            continue

    return done


def run_post_once(base_dir, run_id):
    log_dir = os.path.join(base_dir, "log")
    post_file = os.path.join(base_dir, "post")
    lock_file = os.path.join(log_dir, "post.lock")
    done_file = os.path.join(log_dir, "post.done")

    if not post_has_effective_content(post_file):
        log(f"post_skip reason=no_effective_post base_dir={base_dir} run_id={run_id}")
        return

    os.makedirs(log_dir, exist_ok=True)

    with open(lock_file, "a+", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log(f"post_skip reason=post_locked base_dir={base_dir} run_id={run_id}")
            return

        if os.path.exists(done_file) and os.path.getsize(done_file) > 0:
            log(f"post_skip reason=post_already_done base_dir={base_dir} run_id={run_id}")
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
            log(f"post_done base_dir={base_dir} run_id={run_id} rc={rc} stdout={stdout} stderr={stderr}")
        except subprocess.TimeoutExpired:
            rc = 124
            log(f"post_done base_dir={base_dir} run_id={run_id} rc=124 error=post_timeout")
        except Exception as e:
            rc = 1
            log(f"post_done base_dir={base_dir} run_id={run_id} rc=1 error={e}")

        with open(done_file, "a", encoding="utf-8") as done:
            done.write(f"{run_id}\trc={rc}\tended_at={time.strftime('%Y-%m-%d %H:%M:%S')}\n")


def maybe_run_post(base_dir, run_id):
    expected_hosts = get_expected_hosts(base_dir)

    if not expected_hosts:
        log(f"post_wait reason=no_expected_hosts base_dir={base_dir} run_id={run_id}")
        return

    expected_set = set(expected_hosts)
    done_hosts = get_done_hosts(base_dir)
    missing_hosts = sorted(expected_set - done_hosts)

    if missing_hosts:
        return

    run_post_once(base_dir, run_id)


def handle_async_done(payload):
    run_id = str(payload.get("run_id", "unknown"))
    base_dir = str(payload.get("base_dir", "")).strip()
    minion_id = str(payload.get("minion_id", "")).strip()
    status = str(payload.get("status", "unknown"))
    exit_code_raw = payload.get("exit_code", 1)

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

    if not is_safe_base_dir(base_dir):
        log(f"async_done_skip reason=invalid_base_dir base_dir={base_dir} run_id={run_id} minion={minion_id}")
        return

    if not is_safe_minion_id(minion_id):
        log(f"async_done_skip reason=invalid_minion_id base_dir={base_dir} run_id={run_id} minion={minion_id}")
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
    # 1. stderr 가 있으면:
    #    - stdout 은 result 에 저장
    #    - stderr 는 error 에 저장
    #
    # 2. stderr 가 없고 실패이면:
    #    - stdout 이 있으면 error 에만 저장
    #    - stdout 도 없으면 빈 error 파일 생성
    #
    # 3. 성공이면:
    #    - stdout 을 result 에 저장
    #    - stdout 이 없어도 빈 result 파일 생성
    #    - 기존 error 파일은 제거
    # ============================================================
    if stderr_content:
        if stdout_content:
            write_text_file(result_file, stdout_content)
            wrote_result = True

        write_text_file(error_file, stderr_content)
        wrote_error = True

    elif is_failed:
        if stdout_content:
            write_text_file(error_file, stdout_content)
        else:
            write_text_file(error_file, "")

        wrote_error = True

        try:
            if os.path.exists(result_file):
                os.remove(result_file)
        except Exception:
            pass

    else:
        write_text_file(result_file, stdout_content)
        wrote_result = True

        try:
            if os.path.exists(error_file):
                os.remove(error_file)
        except Exception:
            pass

    log(
        f"async_result_written base_dir={base_dir} run_id={run_id} "
        f"minion={minion_id} rc={exit_code} "
        f"result={'yes' if wrote_result else 'no'} "
        f"error={'yes' if wrote_error else 'no'}"
    )

    maybe_run_post(base_dir, run_id)

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

        log(f"event_skip reason=unsupported_event_type tag={tag} run_id={run_id} minion={minion_id}")


if __name__ == "__main__":
    main()

