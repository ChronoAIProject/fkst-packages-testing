#!/usr/bin/env python3
import ctypes
import json
import os
import secrets
import stat
import sys


MAX_REQUEST_BYTES = 32 * 1024
MAX_ENTRIES, MAX_DEPTH = 100_000, 128
REQUEST_SCHEMA = "environment-factory.object-bound-cleanup-request.v1"
RECEIPT_SCHEMA = "environment-factory.object-bound-cleanup-receipt.v1"
ALLOCATION_REQUEST_SCHEMA = "environment-factory.object-bound-directory-allocation-request.v1"
ALLOCATION_RECEIPT_SCHEMA = "environment-factory.object-bound-directory-allocation-receipt.v1"
MARKER_RETIREMENT_REQUEST_SCHEMA = "environment-factory.object-bound-marker-retirement-request.v1"
MARKER_RETIREMENT_RECEIPT_SCHEMA = "environment-factory.object-bound-marker-retirement-receipt.v1"
ALLOCATION_STAGE_PREFIX = ".fkst-object-allocation-"
QUARANTINE_PREFIX = ".fkst-object-cleanup-"
QUARANTINE_SLOT, CAPTURE_MARKER = "entry", "capture.json"
CAPTURE_CLEANED_MARKER = "captured-cleaned"
CAPTURE_RETAINED_MARKER = "captured-retained"
CAPTURE_FINALIZED_MARKER = "finalized"
CAPTURE_MARKER_SCHEMA = "environment-factory.object-bound-cleanup-capture.v1"
RENAME_NOREPLACE, RENAME_EXCL = 1, 0x00000004


class CleanupBlocked(Exception):
    pass


def same_object(left, right):
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def identity_matches(observed, expected):
    return (
        isinstance(expected, dict)
        and str(observed.st_dev) == expected.get("device")
        and str(observed.st_ino) == expected.get("inode")
    )


def valid_digest(value):
    return isinstance(value, str) and len(value) == 64 and all(
        char in "0123456789abcdef" for char in value
    )


def valid_identity(value):
    return isinstance(value, dict) and set(value) == {"realpath", "device", "inode"} and all(
        isinstance(value.get(key), str) and value[key] for key in value
    )


def valid_absolute_path(value):
    return isinstance(value, str) and os.path.isabs(value) and "\x00" not in value


def read_cleanup_request(value):
    expected_keys = {
        "schema",
        "operation",
        "capture_id",
        "target",
        "target_identity",
        "containment_root",
        "containment_root_identity",
    }
    if set(value) != expected_keys or value.get("schema") != REQUEST_SCHEMA:
        raise CleanupBlocked("request-invalid")
    if value.get("operation") not in ("capture-delete", "finalize", "release-proof"):
        raise CleanupBlocked("operation-invalid")
    if not valid_digest(value.get("capture_id")):
        raise CleanupBlocked("capture-id-invalid")
    for name in ("target", "containment_root"):
        if not valid_absolute_path(value.get(name)):
            raise CleanupBlocked("path-invalid")
    for name in ("target_identity", "containment_root_identity"):
        if not valid_identity(value.get(name)):
            raise CleanupBlocked("identity-invalid")
    return value


def valid_relative_directory(value):
    if not isinstance(value, str) or not value or "\x00" in value or os.path.isabs(value):
        return False
    segments = value.split("/")
    return all(segment not in ("", ".", "..") and os.sep not in segment for segment in segments)


def read_allocation_request(value):
    expected_keys = {
        "schema",
        "operation",
        "allocation_id",
        "target",
        "containment_root",
        "containment_root_identity",
        "marker_name",
        "marker_body",
        "child_directories",
    }
    if set(value) != expected_keys or value.get("schema") != ALLOCATION_REQUEST_SCHEMA:
        raise CleanupBlocked("allocation-request-invalid")
    allocation_id = value.get("allocation_id")
    if value.get("operation") != "allocate-directory" or not valid_digest(allocation_id):
        raise CleanupBlocked("allocation-binding-invalid")
    for name in ("target", "containment_root"):
        if not valid_absolute_path(value.get(name)):
            raise CleanupBlocked("allocation-path-invalid")
    identity = value.get("containment_root_identity")
    if not valid_identity(identity):
        raise CleanupBlocked("allocation-root-identity-invalid")
    marker_name = value.get("marker_name")
    marker_body = value.get("marker_body")
    children = value.get("child_directories")
    if (
        not isinstance(marker_name, str)
        or marker_name in ("", ".", "..")
        or os.sep in marker_name
        or "\x00" in marker_name
        or not isinstance(marker_body, str)
        or not marker_body.endswith("\n")
        or len(marker_body.encode("utf-8")) > 16 * 1024
        or not isinstance(children, list)
        or len(children) > 16
        or len(set(children)) != len(children)
        or not all(valid_relative_directory(item) for item in children)
    ):
        raise CleanupBlocked("allocation-content-invalid")
    return value


def read_marker_retirement_request(value):
    expected_keys = {
        "schema",
        "operation",
        "allocation_id",
        "target",
        "target_identity",
        "containment_root",
        "containment_root_identity",
        "marker_name",
        "marker_body",
    }
    if set(value) != expected_keys or value.get("schema") != MARKER_RETIREMENT_REQUEST_SCHEMA:
        raise CleanupBlocked("marker-retirement-request-invalid")
    allocation_id = value.get("allocation_id")
    if value.get("operation") != "retire-marker" or not valid_digest(allocation_id):
        raise CleanupBlocked("marker-retirement-binding-invalid")
    for name in ("target", "containment_root"):
        if not valid_absolute_path(value.get(name)):
            raise CleanupBlocked("marker-retirement-path-invalid")
    for name in ("target_identity", "containment_root_identity"):
        if not valid_identity(value.get(name)):
            raise CleanupBlocked("marker-retirement-identity-invalid")
    marker_name = value.get("marker_name")
    marker_body = value.get("marker_body")
    if (
        not isinstance(marker_name, str)
        or marker_name in ("", ".", "..")
        or os.sep in marker_name
        or "\x00" in marker_name
        or not isinstance(marker_body, str)
        or not marker_body.endswith("\n")
        or len(marker_body.encode("utf-8")) > 16 * 1024
    ):
        raise CleanupBlocked("marker-retirement-content-invalid")
    return value


def read_request():
    body = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(body) > MAX_REQUEST_BYTES:
        raise CleanupBlocked("request-too-large")
    try:
        value = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CleanupBlocked("request-invalid") from error
    if not isinstance(value, dict):
        raise CleanupBlocked("request-invalid")
    if value.get("schema") == ALLOCATION_REQUEST_SCHEMA:
        return read_allocation_request(value)
    if value.get("schema") == MARKER_RETIREMENT_REQUEST_SCHEMA:
        return read_marker_retirement_request(value)
    return read_cleanup_request(value)


def open_directory(name, parent_fd=None):
    flags = os.O_RDONLY | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return os.open(name, flags, dir_fd=parent_fd)


def rename_noreplace(source_name, source_fd, destination_name, destination_fd):
    libc = ctypes.CDLL(None, use_errno=True)
    encoded_source = os.fsencode(source_name)
    encoded_destination = os.fsencode(destination_name)
    if sys.platform.startswith("linux"):
        primitive = getattr(libc, "renameat2", None)
        flags = RENAME_NOREPLACE
    elif sys.platform == "darwin":
        primitive = getattr(libc, "renameatx_np", None)
        flags = RENAME_EXCL
    else:
        raise CleanupBlocked("atomic-capture-unsupported")
    if primitive is None:
        raise CleanupBlocked("atomic-capture-unsupported")
    primitive.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    primitive.restype = ctypes.c_int
    ctypes.set_errno(0)
    if primitive(source_fd, encoded_source, destination_fd, encoded_destination, flags) != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), source_name)


def stat_entry(directory_fd, name):
    return os.stat(name, dir_fd=directory_fd, follow_symlinks=False)


def create_private_quarantine(parent_fd, filesystem_device):
    for _ in range(16):
        name = QUARANTINE_PREFIX + secrets.token_hex(16)
        try:
            os.mkdir(name, mode=0o700, dir_fd=parent_fd)
        except FileExistsError:
            continue
        directory_fd = None
        linked = None
        try:
            linked = stat_entry(parent_fd, name)
            directory_fd = open_directory(name, parent_fd)
            opened = os.fstat(directory_fd)
            if (
                not stat.S_ISDIR(linked.st_mode)
                or not same_object(linked, opened)
                or opened.st_dev != filesystem_device
                or opened.st_uid != os.geteuid()
                or opened.st_mode & 0o077
            ):
                raise CleanupBlocked("quarantine-invalid")
            return name, directory_fd, opened
        except Exception:
            if directory_fd is not None:
                os.close(directory_fd)
            try:
                current = stat_entry(parent_fd, name)
                if linked is not None and same_object(current, linked):
                    os.rmdir(name, dir_fd=parent_fd)
            except OSError:
                pass
            raise
    raise CleanupBlocked("quarantine-allocation-failed")


def capture_marker_body(request):
    return (
        json.dumps(
            {
                "schema": CAPTURE_MARKER_SCHEMA,
                "capture_id": request["capture_id"],
                "target": request["target"],
                "target_identity": request["target_identity"],
                "containment_root": request["containment_root"],
                "containment_root_identity": request["containment_root_identity"],
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        + b"\n"
    )


def write_exclusive_file(directory_fd, name, body):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(name, flags, 0o600, dir_fd=directory_fd)
    try:
        offset = 0
        while offset < len(body):
            written = os.write(descriptor, body[offset:])
            if written <= 0:
                raise CleanupBlocked("capture-marker-write-failed")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def read_bound_file(directory_fd, name, maximum=4096):
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(name, flags, dir_fd=directory_fd)
    try:
        linked = stat_entry(directory_fd, name)
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(linked.st_mode)
            or not same_object(linked, opened)
            or opened.st_uid != os.geteuid()
            or opened.st_mode & 0o077
            or opened.st_size > maximum
        ):
            raise CleanupBlocked("capture-marker-invalid")
        chunks = []
        remaining = maximum + 1
        while remaining > 0:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        body = b"".join(chunks)
        if len(body) > maximum:
            raise CleanupBlocked("capture-marker-invalid")
        return body
    finally:
        os.close(descriptor)


def marker_exists(directory_fd, name):
    try:
        stat_entry(directory_fd, name)
    except FileNotFoundError:
        return False
    return True


def capture_quarantine_name(request):
    return QUARANTINE_PREFIX + request["capture_id"]


def open_capture_quarantine(bound, request, create):
    name = capture_quarantine_name(request)
    created = False
    if create:
        try:
            os.mkdir(name, mode=0o700, dir_fd=bound["parent_fd"])
            created = True
        except FileExistsError:
            pass
    elif not marker_exists(bound["parent_fd"], name):
        return None
    if not created and not marker_exists(bound["parent_fd"], name):
        if not create:
            return None
        raise CleanupBlocked("capture-quarantine-missing")
    directory_fd = open_directory(name, bound["parent_fd"])
    try:
        linked = stat_entry(bound["parent_fd"], name)
        opened = os.fstat(directory_fd)
        if (
            not stat.S_ISDIR(linked.st_mode)
            or not same_object(linked, opened)
            or opened.st_dev != bound["root_stat"].st_dev
            or opened.st_uid != os.geteuid()
            or opened.st_mode & 0o077
        ):
            raise CleanupBlocked("capture-quarantine-invalid")
        expected_marker = capture_marker_body(request)
        if created:
            write_exclusive_file(directory_fd, CAPTURE_MARKER, expected_marker)
            os.fsync(directory_fd)
        if read_bound_file(directory_fd, CAPTURE_MARKER) != expected_marker:
            raise CleanupBlocked("capture-marker-binding-mismatch")
        return {"name": name, "fd": directory_fd, "stat": opened}
    except Exception:
        os.close(directory_fd)
        if created:
            try:
                os.rmdir(name, dir_fd=bound["parent_fd"])
            except OSError:
                pass
        raise


def entry_is_absent(directory_fd, name):
    try:
        stat_entry(directory_fd, name)
    except FileNotFoundError:
        return True
    return False


def remove_empty_quarantine(parent_fd, name, directory_fd, expected):
    if os.listdir(directory_fd):
        return False
    try:
        current = stat_entry(parent_fd, name)
        if not same_object(current, expected):
            return False
        os.rmdir(name, dir_fd=parent_fd)
        return True
    except OSError:
        return False


def restore_captured_entry(source_fd, source_name, quarantine_fd, captured):
    current = stat_entry(quarantine_fd, QUARANTINE_SLOT)
    if not same_object(current, captured):
        raise CleanupBlocked("captured-entry-changed")
    try:
        rename_noreplace(QUARANTINE_SLOT, quarantine_fd, source_name, source_fd)
    except OSError as error:
        raise CleanupBlocked("captured-entry-retained") from error
    restored = stat_entry(source_fd, source_name)
    if not same_object(restored, captured):
        raise CleanupBlocked("restored-entry-changed")


def capture_observed_entry(source_fd, source_name, observed, quarantine_fd):
    rename_noreplace(source_name, source_fd, QUARANTINE_SLOT, quarantine_fd)
    captured = stat_entry(quarantine_fd, QUARANTINE_SLOT)
    if not same_object(captured, observed):
        restore_captured_entry(source_fd, source_name, quarantine_fd, captured)
        raise CleanupBlocked("entry-changed-before-capture")
    return captured


def clear_directory(directory_fd, filesystem_device, budget, depth=0):
    if depth > MAX_DEPTH:
        raise CleanupBlocked("depth-exceeded")
    quarantine_name, quarantine_fd, quarantine_stat = create_private_quarantine(
        directory_fd, filesystem_device,
    )
    try:
        names = [name for name in os.listdir(directory_fd) if name != quarantine_name]
        for name in names:
            if name in (".", "..") or os.sep in name or "\x00" in name:
                raise CleanupBlocked("entry-invalid")
            budget[0] += 1
            if budget[0] > MAX_ENTRIES:
                raise CleanupBlocked("entry-limit-exceeded")
            observed = stat_entry(directory_fd, name)
            if observed.st_dev != filesystem_device:
                raise CleanupBlocked("filesystem-boundary-crossed")
            captured = capture_observed_entry(directory_fd, name, observed, quarantine_fd)
            if stat.S_ISDIR(captured.st_mode):
                child_fd = open_directory(QUARANTINE_SLOT, quarantine_fd)
                try:
                    opened = os.fstat(child_fd)
                    if not same_object(opened, captured):
                        raise CleanupBlocked("captured-directory-changed")
                    clear_directory(child_fd, filesystem_device, budget, depth + 1)
                    current = stat_entry(quarantine_fd, QUARANTINE_SLOT)
                    if not same_object(current, opened):
                        raise CleanupBlocked("captured-directory-changed")
                    os.rmdir(QUARANTINE_SLOT, dir_fd=quarantine_fd)
                finally:
                    os.close(child_fd)
            else:
                current = stat_entry(quarantine_fd, QUARANTINE_SLOT)
                if not same_object(current, captured):
                    raise CleanupBlocked("captured-entry-changed")
                os.unlink(QUARANTINE_SLOT, dir_fd=quarantine_fd)
            if not entry_is_absent(directory_fd, name):
                raise CleanupBlocked("source-entry-reappeared")
        remaining = [name for name in os.listdir(directory_fd) if name != quarantine_name]
        if remaining:
            raise CleanupBlocked("directory-changed-during-cleanup")
    finally:
        os.close(quarantine_fd)
        cleanup_fd = None
        try:
            cleanup_fd = open_directory(quarantine_name, directory_fd)
            cleanup_stat = os.fstat(cleanup_fd)
            if same_object(cleanup_stat, quarantine_stat):
                remove_empty_quarantine(directory_fd, quarantine_name, cleanup_fd, quarantine_stat)
        except OSError:
            pass
        finally:
            if cleanup_fd is not None:
                os.close(cleanup_fd)


def open_bound_root(request):
    root = os.path.normpath(request["containment_root"])
    target = os.path.normpath(request["target"])
    if root != request["containment_root_identity"]["realpath"]:
        raise CleanupBlocked("root-path-mismatch")
    if target != request["target_identity"]["realpath"]:
        raise CleanupBlocked("target-path-mismatch")
    if os.path.dirname(target) != root or os.path.basename(target) in ("", ".", ".."):
        raise CleanupBlocked("target-must-be-direct-child")
    root_parent = os.path.dirname(root)
    root_name = os.path.basename(root)
    if not root_parent or root_name in ("", ".", ".."):
        raise CleanupBlocked("containment-invalid")

    parent_fd = open_directory(root_parent)
    opened = [parent_fd]
    try:
        parent_stat = os.fstat(parent_fd)
        linked_root = stat_entry(parent_fd, root_name)
        root_fd = open_directory(root_name, parent_fd)
        opened.append(root_fd)
        root_stat = os.fstat(root_fd)
        if (
            not same_object(linked_root, root_stat)
            or not identity_matches(root_stat, request["containment_root_identity"])
        ):
            raise CleanupBlocked("root-identity-mismatch")
        return {
            "opened": opened,
            "parent_fd": parent_fd,
            "parent_stat": parent_stat,
            "root_name": root_name,
            "root_fd": root_fd,
            "root_stat": root_stat,
            "target_name": os.path.basename(target),
        }
    except Exception:
        for descriptor in reversed(opened):
            os.close(descriptor)
        raise


def open_allocation_root(request):
    root = os.path.normpath(request["containment_root"])
    target = os.path.normpath(request["target"])
    if root != request["containment_root_identity"]["realpath"]:
        raise CleanupBlocked("allocation-root-path-mismatch")
    if os.path.dirname(target) != root or os.path.basename(target) in ("", ".", ".."):
        raise CleanupBlocked("allocation-target-must-be-direct-child")
    root_parent = os.path.dirname(root)
    root_name = os.path.basename(root)
    if not root_parent or root_name in ("", ".", ".."):
        raise CleanupBlocked("allocation-containment-invalid")

    parent_fd = open_directory(root_parent)
    opened = [parent_fd]
    try:
        parent_stat = os.fstat(parent_fd)
        linked_root = stat_entry(parent_fd, root_name)
        root_fd = open_directory(root_name, parent_fd)
        opened.append(root_fd)
        root_stat = os.fstat(root_fd)
        if (
            not same_object(linked_root, root_stat)
            or not identity_matches(root_stat, request["containment_root_identity"])
            or root_stat.st_uid != os.geteuid()
            or root_stat.st_mode & 0o077
        ):
            raise CleanupBlocked("allocation-root-identity-mismatch")
        return {
            "opened": opened,
            "parent_fd": parent_fd,
            "parent_stat": parent_stat,
            "root_name": root_name,
            "root_fd": root_fd,
            "root_stat": root_stat,
            "target_name": os.path.basename(target),
        }
    except Exception:
        for descriptor in reversed(opened):
            os.close(descriptor)
        raise


def create_bound_child_directories(root_fd, values):
    for relative in sorted(values, key=lambda item: (item.count("/"), item)):
        current_fd = os.dup(root_fd)
        try:
            for segment in relative.split("/"):
                try:
                    os.mkdir(segment, mode=0o700, dir_fd=current_fd)
                except FileExistsError:
                    pass
                child_fd = open_directory(segment, current_fd)
                child_stat = os.fstat(child_fd)
                linked = stat_entry(current_fd, segment)
                if (
                    not stat.S_ISDIR(linked.st_mode)
                    or not same_object(linked, child_stat)
                    or child_stat.st_uid != os.geteuid()
                    or child_stat.st_mode & 0o077
                ):
                    os.close(child_fd)
                    raise CleanupBlocked("allocation-child-invalid")
                os.close(current_fd)
                current_fd = child_fd
            os.fsync(current_fd)
        finally:
            os.close(current_fd)


def validate_allocated_directory(directory_fd, directory_stat, request):
    if (
        not stat.S_ISDIR(directory_stat.st_mode)
        or directory_stat.st_uid != os.geteuid()
        or directory_stat.st_mode & 0o077
    ):
        raise CleanupBlocked("allocated-directory-invalid")
    if read_bound_file(directory_fd, request["marker_name"], 16 * 1024) != request["marker_body"].encode("utf-8"):
        raise CleanupBlocked("allocated-directory-marker-differs")
    expected = {"": {request["marker_name"]}}
    for relative in request["child_directories"]:
        parent = ""
        for segment in relative.split("/"):
            expected.setdefault(parent, set()).add(segment)
            parent = segment if parent == "" else parent + "/" + segment
            expected.setdefault(parent, set())
    for relative, names in expected.items():
        current_fd = os.dup(directory_fd)
        try:
            if relative:
                for segment in relative.split("/"):
                    child_fd = open_directory(segment, current_fd)
                    os.close(current_fd)
                    current_fd = child_fd
            if set(os.listdir(current_fd)) != names:
                raise CleanupBlocked("allocated-directory-contents-differ")
        finally:
            os.close(current_fd)


def allocation_receipt(request, bound, target_stat):
    return {
        "schema": ALLOCATION_RECEIPT_SCHEMA,
        "status": "allocated",
        "allocation_id": request["allocation_id"],
        "target_realpath": request["target"],
        "target_device": str(target_stat.st_dev),
        "target_inode": str(target_stat.st_ino),
        "containment_root_device": str(bound["root_stat"].st_dev),
        "containment_root_inode": str(bound["root_stat"].st_ino),
    }


def allocate_directory(request):
    bound = open_allocation_root(request)
    stage_fd = None
    stage_name = None
    try:
        try:
            existing = stat_entry(bound["root_fd"], bound["target_name"])
        except FileNotFoundError:
            existing = None
        if existing is not None:
            target_fd = open_directory(bound["target_name"], bound["root_fd"])
            try:
                opened = os.fstat(target_fd)
                if not same_object(existing, opened) or opened.st_dev != bound["root_stat"].st_dev:
                    raise CleanupBlocked("allocated-target-changed")
                validate_allocated_directory(target_fd, opened, request)
                if not root_still_bound(bound):
                    raise CleanupBlocked("allocation-root-moved")
                return allocation_receipt(request, bound, opened)
            finally:
                os.close(target_fd)

        for _ in range(16):
            candidate = ALLOCATION_STAGE_PREFIX + secrets.token_hex(16)
            try:
                os.mkdir(candidate, mode=0o700, dir_fd=bound["root_fd"])
                stage_name = candidate
                break
            except FileExistsError:
                continue
        if stage_name is None:
            raise CleanupBlocked("allocation-stage-unavailable")
        stage_fd = open_directory(stage_name, bound["root_fd"])
        linked_stage = stat_entry(bound["root_fd"], stage_name)
        stage_stat = os.fstat(stage_fd)
        if (
            not same_object(linked_stage, stage_stat)
            or stage_stat.st_dev != bound["root_stat"].st_dev
            or stage_stat.st_uid != os.geteuid()
            or stage_stat.st_mode & 0o077
        ):
            raise CleanupBlocked("allocation-stage-invalid")
        write_exclusive_file(
            stage_fd, request["marker_name"], request["marker_body"].encode("utf-8"),
        )
        create_bound_child_directories(stage_fd, request["child_directories"])
        validate_allocated_directory(stage_fd, stage_stat, request)
        os.fsync(stage_fd)
        if not root_still_bound(bound):
            raise CleanupBlocked("allocation-root-moved-before-publish")
        rename_noreplace(stage_name, bound["root_fd"], bound["target_name"], bound["root_fd"])
        stage_name = None
        os.fsync(bound["root_fd"])
        published = stat_entry(bound["root_fd"], bound["target_name"])
        if not same_object(published, stage_stat) or not root_still_bound(bound):
            raise CleanupBlocked("allocated-target-changed-after-publish")
        return allocation_receipt(request, bound, published)
    finally:
        if stage_fd is not None:
            os.close(stage_fd)
        if stage_name is not None:
            try:
                os.rmdir(stage_name, dir_fd=bound["root_fd"])
            except OSError:
                pass
        for descriptor in reversed(bound["opened"]):
            os.close(descriptor)


def retire_directory_marker(request):
    bound = open_bound_root(request)
    target_fd = None
    try:
        target_fd, target_stat = open_expected_target(bound, request)
        expected = request["marker_body"].encode("utf-8")
        if read_bound_file(target_fd, request["marker_name"], 16 * 1024) != expected:
            raise CleanupBlocked("retired-marker-binding-differs")
        os.unlink(request["marker_name"], dir_fd=target_fd)
        os.fsync(target_fd)
        current = stat_entry(bound["root_fd"], bound["target_name"])
        if not same_object(current, target_stat) or not root_still_bound(bound):
            raise CleanupBlocked("retired-marker-target-changed")
        return {
            "schema": MARKER_RETIREMENT_RECEIPT_SCHEMA,
            "status": "retired",
            "allocation_id": request["allocation_id"],
            "target_device": str(target_stat.st_dev),
            "target_inode": str(target_stat.st_ino),
            "containment_root_device": str(bound["root_stat"].st_dev),
            "containment_root_inode": str(bound["root_stat"].st_ino),
        }
    finally:
        if target_fd is not None:
            os.close(target_fd)
        for descriptor in reversed(bound["opened"]):
            os.close(descriptor)


def root_still_bound(bound):
    try:
        return (
            same_object(os.fstat(bound["parent_fd"]), bound["parent_stat"])
            and same_object(stat_entry(bound["parent_fd"], bound["root_name"]), bound["root_stat"])
        )
    except OSError:
        return False


def open_expected_target(bound, request):
    linked_target = stat_entry(bound["root_fd"], bound["target_name"])
    if not stat.S_ISDIR(linked_target.st_mode):
        raise CleanupBlocked("target-not-directory")
    target_fd = open_directory(bound["target_name"], bound["root_fd"])
    try:
        target_stat = os.fstat(target_fd)
        if (
            not same_object(linked_target, target_stat)
            or target_stat.st_dev != bound["root_stat"].st_dev
            or not identity_matches(target_stat, request["target_identity"])
        ):
            raise CleanupBlocked("target-identity-mismatch")
        return target_fd, target_stat
    except Exception:
        os.close(target_fd)
        raise


def capture_receipt(request, bound, status):
    return {
        "schema": RECEIPT_SCHEMA,
        "status": status,
        "capture_id": request["capture_id"],
        "target_removed": True,
        "target_device": request["target_identity"]["device"],
        "target_inode": request["target_identity"]["inode"],
        "containment_root_device": str(bound["root_stat"].st_dev),
        "containment_root_inode": str(bound["root_stat"].st_ino),
    }


def marker_token(request, state):
    return (state + ":" + request["capture_id"] + "\n").encode("ascii")


def mark_capture_retained(quarantine_fd, request):
    if marker_exists(quarantine_fd, CAPTURE_CLEANED_MARKER):
        return
    if not marker_exists(quarantine_fd, CAPTURE_RETAINED_MARKER):
        write_exclusive_file(
            quarantine_fd,
            CAPTURE_RETAINED_MARKER,
            marker_token(request, "retained"),
        )
        os.fsync(quarantine_fd)


def validate_capture_entries(quarantine_fd):
    names = set(os.listdir(quarantine_fd))
    allowed = {
        CAPTURE_MARKER,
        CAPTURE_CLEANED_MARKER,
        CAPTURE_RETAINED_MARKER,
        CAPTURE_FINALIZED_MARKER,
        QUARANTINE_SLOT,
    }
    if not names.issubset(allowed):
        raise CleanupBlocked("capture-quarantine-contains-unknown-entry")
    return names


def capture_delete(request):
    bound = open_bound_root(request)
    quarantine = None
    target_fd = None
    captured = None
    delete_started = False
    try:
        quarantine = open_capture_quarantine(bound, request, True)
        names = validate_capture_entries(quarantine["fd"])
        if CAPTURE_RETAINED_MARKER in names:
            if read_bound_file(quarantine["fd"], CAPTURE_RETAINED_MARKER) != marker_token(request, "retained"):
                raise CleanupBlocked("capture-retained-marker-invalid")
            raise CleanupBlocked("captured-resource-retained")
        if CAPTURE_CLEANED_MARKER in names:
            if (
                QUARANTINE_SLOT in names
                or read_bound_file(quarantine["fd"], CAPTURE_CLEANED_MARKER)
                != marker_token(request, "cleaned")
            ):
                raise CleanupBlocked("capture-cleaned-marker-invalid")
            return capture_receipt(request, bound, "captured-cleaned")

        if QUARANTINE_SLOT in names:
            captured = stat_entry(quarantine["fd"], QUARANTINE_SLOT)
            if (
                not stat.S_ISDIR(captured.st_mode)
                or not identity_matches(captured, request["target_identity"])
            ):
                raise CleanupBlocked("captured-target-changed")
            target_fd = open_directory(QUARANTINE_SLOT, quarantine["fd"])
            if not same_object(os.fstat(target_fd), captured):
                raise CleanupBlocked("captured-target-changed")
        else:
            target_fd, observed = open_expected_target(bound, request)
            captured = capture_observed_entry(
                bound["root_fd"], bound["target_name"], observed, quarantine["fd"],
            )
            if not same_object(os.fstat(target_fd), captured):
                raise CleanupBlocked("captured-target-changed")

        if not root_still_bound(bound):
            raise CleanupBlocked("root-moved-before-capture-completed")
        if not entry_is_absent(bound["root_fd"], bound["target_name"]):
            raise CleanupBlocked("target-reappeared-before-delete")
        current = stat_entry(quarantine["fd"], QUARANTINE_SLOT)
        if not same_object(current, captured) or not same_object(current, os.fstat(target_fd)):
            raise CleanupBlocked("captured-target-changed")

        delete_started = True
        clear_directory(target_fd, captured.st_dev, [0])
        current = stat_entry(quarantine["fd"], QUARANTINE_SLOT)
        if not same_object(current, captured):
            raise CleanupBlocked("captured-target-changed")
        os.rmdir(QUARANTINE_SLOT, dir_fd=quarantine["fd"])
        if not root_still_bound(bound):
            raise CleanupBlocked("root-moved-during-cleanup")
        write_exclusive_file(
            quarantine["fd"],
            CAPTURE_CLEANED_MARKER,
            marker_token(request, "cleaned"),
        )
        os.fsync(quarantine["fd"])
        return capture_receipt(request, bound, "captured-cleaned")
    except Exception:
        if quarantine is not None:
            if captured is not None and not delete_started:
                try:
                    if entry_is_absent(bound["root_fd"], bound["target_name"]):
                        restore_captured_entry(
                            bound["root_fd"], bound["target_name"], quarantine["fd"], captured,
                        )
                        captured = None
                except (CleanupBlocked, OSError):
                    pass
            try:
                mark_capture_retained(quarantine["fd"], request)
            except (CleanupBlocked, OSError):
                pass
        raise
    finally:
        if target_fd is not None:
            os.close(target_fd)
        if quarantine is not None:
            os.close(quarantine["fd"])
        for descriptor in reversed(bound["opened"]):
            os.close(descriptor)


def finalize_capture(request):
    bound = open_bound_root(request)
    quarantine = None
    try:
        quarantine = open_capture_quarantine(bound, request, False)
        if quarantine is None:
            raise CleanupBlocked("capture-proof-missing")
        names = validate_capture_entries(quarantine["fd"])
        expected_names = {CAPTURE_MARKER, CAPTURE_CLEANED_MARKER}
        if CAPTURE_FINALIZED_MARKER in names:
            expected_names.add(CAPTURE_FINALIZED_MARKER)
        if names != expected_names:
            raise CleanupBlocked("capture-not-finalizable")
        if (
            read_bound_file(quarantine["fd"], CAPTURE_CLEANED_MARKER)
            != marker_token(request, "cleaned")
        ):
            raise CleanupBlocked("capture-cleaned-marker-invalid")
        if CAPTURE_FINALIZED_MARKER in names:
            if (
                read_bound_file(quarantine["fd"], CAPTURE_FINALIZED_MARKER)
                != marker_token(request, "finalized")
            ):
                raise CleanupBlocked("capture-finalized-marker-invalid")
        else:
            write_exclusive_file(
                quarantine["fd"],
                CAPTURE_FINALIZED_MARKER,
                marker_token(request, "finalized"),
            )
        os.fsync(quarantine["fd"])
        return capture_receipt(request, bound, "finalized")
    finally:
        if quarantine is not None:
            os.close(quarantine["fd"])
        for descriptor in reversed(bound["opened"]):
            os.close(descriptor)


def release_capture_proof(request):
    bound = open_bound_root(request)
    quarantine = None
    try:
        quarantine = open_capture_quarantine(bound, request, False)
        if quarantine is None:
            return capture_receipt(request, bound, "released")
        names = validate_capture_entries(quarantine["fd"])
        if names != {CAPTURE_MARKER, CAPTURE_CLEANED_MARKER, CAPTURE_FINALIZED_MARKER}:
            raise CleanupBlocked("capture-proof-not-releasable")
        if (
            read_bound_file(quarantine["fd"], CAPTURE_CLEANED_MARKER)
            != marker_token(request, "cleaned")
            or read_bound_file(quarantine["fd"], CAPTURE_FINALIZED_MARKER)
            != marker_token(request, "finalized")
        ):
            raise CleanupBlocked("capture-proof-marker-invalid")
        for name in (CAPTURE_FINALIZED_MARKER, CAPTURE_CLEANED_MARKER, CAPTURE_MARKER):
            os.unlink(name, dir_fd=quarantine["fd"])
        os.fsync(quarantine["fd"])
        linked = stat_entry(bound["parent_fd"], quarantine["name"])
        if not same_object(linked, quarantine["stat"]):
            raise CleanupBlocked("capture-quarantine-changed")
        os.rmdir(quarantine["name"], dir_fd=bound["parent_fd"])
        os.fsync(bound["parent_fd"])
        return capture_receipt(request, bound, "released")
    finally:
        if quarantine is not None:
            os.close(quarantine["fd"])
        for descriptor in reversed(bound["opened"]):
            os.close(descriptor)


def cleanup(request):
    if request["operation"] == "capture-delete":
        return capture_delete(request)
    if request["operation"] == "finalize":
        return finalize_capture(request)
    if request["operation"] == "release-proof":
        return release_capture_proof(request)
    raise CleanupBlocked("operation-invalid")


def execute(request):
    if request["schema"] == ALLOCATION_REQUEST_SCHEMA:
        return allocate_directory(request)
    if request["schema"] == MARKER_RETIREMENT_REQUEST_SCHEMA:
        return retire_directory_marker(request)
    return cleanup(request)


def emit(value):
    sys.stdout.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def main():
    try:
        emit(execute(read_request()))
    except (CleanupBlocked, FileNotFoundError, NotADirectoryError, PermissionError, OSError):
        emit({
            "schema": RECEIPT_SCHEMA,
            "status": "blocked",
            "reason": "OBJECT_BOUND_DIRECTORY_OPERATION_FAILED",
        })
        raise SystemExit(2)


if __name__ == "__main__":
    main()
