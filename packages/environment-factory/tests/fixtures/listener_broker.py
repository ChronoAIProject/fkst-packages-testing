#!/usr/bin/env python3
import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(sys.argv[1])
CONFIG_PATH = ROOT / "config.json"
READY_PATH = ROOT / "ready.json"
ERROR_PATH = ROOT / "error.json"
COMMAND_PATH = ROOT / "command.json"
RESPONSE_PATH = ROOT / "response.json"
RELEASE_PATH = ROOT / "release"
RELEASED_PATH = ROOT / "released.json"


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def close_listeners(listeners):
    for listener in listeners:
        try:
            listener.close()
        except OSError:
            pass


def fail(message, listeners):
    close_listeners(listeners)
    write_json(ERROR_PATH, {"error": str(message)[:512]})
    raise SystemExit(1)


def main():
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    declared = config.get("listeners")
    if not isinstance(declared, list) or not declared:
        fail("listeners must be a non-empty list", [])

    listeners = []
    try:
        for index, item in enumerate(declared):
            listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
            listener.bind(("127.0.0.1", int(item["port"])))
            listener.listen(128)
            expected_fd = 3 + index
            if listener.fileno() != expected_fd:
                raise RuntimeError(
                    f"listener descriptor {listener.fileno()} is not expected fd {expected_fd}"
                )
            listener.set_inheritable(True)
            listeners.append(listener)
    except Exception as error:
        fail(error, listeners)

    released = False

    def release(_signum=None, _frame=None):
        nonlocal released
        if released:
            return
        released = True
        close_listeners(listeners)
        write_json(RELEASED_PATH, {"released": True})

    signal.signal(signal.SIGTERM, release)
    signal.signal(signal.SIGINT, release)
    write_json(READY_PATH, {"listeners": declared, "pid": os.getpid()})

    while not released:
        if RELEASE_PATH.exists():
            release()
            break
        if not COMMAND_PATH.exists():
            time.sleep(0.01)
            continue

        try:
            command = json.loads(COMMAND_PATH.read_text(encoding="utf-8"))
            argv = command["argv"]
            names = command["names"]
            if not isinstance(argv, list) or not argv or not isinstance(names, list):
                raise RuntimeError("broker command is malformed")
            if names != [item["name"] for item in declared]:
                raise RuntimeError("broker listener names differ from the claimed group")
            environment = os.environ.copy()
            environment["FKST_LISTEN_FDS"] = str(len(listeners))
            environment["FKST_LISTEN_FDNAMES"] = ":".join(names)
            with open(command["stdout_path"], "wb") as stdout_file, open(
                command["stderr_path"], "wb"
            ) as stderr_file:
                try:
                    completed = subprocess.run(
                        argv,
                        cwd=command["cwd"],
                        env=environment,
                        stdin=subprocess.DEVNULL,
                        stdout=stdout_file,
                        stderr=stderr_file,
                        timeout=float(command["timeout_seconds"]),
                        check=False,
                        pass_fds=tuple(listener.fileno() for listener in listeners),
                    )
                    response = {"exit_code": completed.returncode, "timed_out": False}
                except subprocess.TimeoutExpired:
                    response = {"exit_code": -1, "timed_out": True}
            close_listeners(listeners)
            write_json(RESPONSE_PATH, response)
            return
        except Exception as error:
            fail(error, listeners)


if __name__ == "__main__":
    main()
