"""Independent Linux worker for the durable studio queue."""
import concurrent.futures
import ctypes
import errno
import fcntl
import json
import os
import resource
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from catalog import ROOT, TOOLS, revision, select_project
from sdk import MAX_REPORT_BYTES
from store import Store

GIB = 1024 ** 3
SAMPLE_INTERVAL = 1
HEARTBEAT_INTERVAL = 3


class JobStopped(Exception):
    pass


class ScopedSandbox:
    """Expose only public runtimes, reviewed code and per-job directories."""
    def __init__(self):
        self.bwrap = shutil.which("bwrap")
        self.godot = self.resolve("godot")
        self.blender = self.resolve("blender")
        if not self.bwrap:
            raise RuntimeError("Bubblewrap is required for automation execution")

    @staticmethod
    def resolve(executable):
        binary = shutil.which(executable, path=str(Path.home() / ".local/bin") + ":" + os.defpath)
        return Path(binary).resolve() if binary else None

    @staticmethod
    def network_filter(file):
        # Disallow network socket families and io_uring as an alternate network entry point.
        class Compare(ctypes.Structure):
            _fields_ = [("arg", ctypes.c_uint), ("op", ctypes.c_int),
                        ("datum_a", ctypes.c_uint64), ("datum_b", ctypes.c_uint64)]

        lib = ctypes.CDLL("libseccomp.so.2")
        lib.seccomp_init.argtypes = [ctypes.c_uint32]
        lib.seccomp_init.restype = ctypes.c_void_p
        lib.seccomp_rule_add_array.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int,
                                              ctypes.c_uint, ctypes.POINTER(Compare)]
        lib.seccomp_syscall_resolve_name.argtypes = [ctypes.c_char_p]
        lib.seccomp_export_bpf.argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.seccomp_release.argtypes = [ctypes.c_void_p]
        ctx = lib.seccomp_init(0x7fff0000)
        if not ctx:
            raise RuntimeError("Could not initialize network syscall filter")
        try:
            deny = 0x00050000 | errno.EPERM
            rule = Compare(0, 1, socket.AF_UNIX, 0)  # SCMP_CMP_NE
            for name in (b"socket", b"socketpair", b"io_uring_setup"):
                number = lib.seccomp_syscall_resolve_name(name)
                if number < 0 or lib.seccomp_rule_add_array(
                    ctx, deny, number, 1 if name == b"socketpair" else 0, ctypes.byref(rule),
                ) < 0:
                    raise RuntimeError("Could not configure network syscall filter")
            if lib.seccomp_export_bpf(ctx, file.fileno()) < 0:
                raise RuntimeError("Could not export network syscall filter")
            file.seek(0)
        finally:
            lib.seccomp_release(ctx)

    def start(self, scratch, args, objects=None, tool=None):
        command = [self.bwrap, "--unshare-user", "--unshare-pid", "--unshare-ipc", "--unshare-uts",
                   "--disable-userns", "--die-with-parent", "--new-session", "--clearenv", "--cap-drop", "ALL",
                   "--proc", "/proc", "--dev", "/dev", "--ro-bind", "/usr", "/usr"]
        for directory in ("/bin", "/lib", "/lib64"):
            if Path(directory).exists():
                command += ["--ro-bind", directory, directory]
        for system_file in ("/etc/ld.so.cache", "/etc/fonts", "/etc/ssl/certs"):
            if Path(system_file).exists():
                command += ["--ro-bind", system_file, system_file]
        command += ["--ro-bind", str(ROOT), "/toolkit", "--bind", str(scratch), "/job",
                    "--bind", str(scratch / "tmp"), "/tmp", "--chdir", "/job",
                    "--setenv", "PATH", "/usr/bin:/bin", "--setenv", "HOME", "/job/home",
                    "--setenv", "XDG_CONFIG_HOME", "/job/home/config",
                    "--setenv", "XDG_CACHE_HOME", "/job/home/cache",
                    "--setenv", "XDG_DATA_HOME", "/job/home/data", "--setenv", "XDG_RUNTIME_DIR", "/job/home",
                    "--setenv", "LANG", "C.UTF-8",
                    "--setenv", "OMP_NUM_THREADS", "2", "--setenv", "OPENBLAS_NUM_THREADS", "2"]
        if objects:
            command += ["--ro-bind", str(objects), "/objects"]
        if self.godot and tool in {"godot.audit", "godot.regression"}:
            command += ["--ro-bind", str(self.godot), "/runtime/godot"]
        if self.blender and tool == "blender.inspect":
            command += ["--ro-bind", str(self.blender.parent), "/runtime/blender"]
        with tempfile.TemporaryFile() as network:
            self.network_filter(network)
            command += ["--seccomp", str(network.fileno()), "--", "/usr/bin/prlimit", "--nofile=512",
                        "--as=6442450944", "--fsize=536870912", "--core=0", "--",
                        sys.executable, "-B", "/toolkit/runner.py", *args]
            return subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, start_new_session=True, pass_fds=(network.fileno(),))


def resources(data):
    mem = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, value = line.split(":", 1)
        if key in {"MemTotal", "MemAvailable"}:
            mem[key] = int(value.split()[0]) * 1024
    partitions = shutil.disk_usage(data)
    gpu = []
    for card in sorted(Path("/sys/class/drm").glob("card[0-9]*")):
        if not card.name[4:].isdigit():
            continue
        try:
            utilization = int((card / "device/gpu_busy_percent").read_text())
        except (OSError, ValueError):
            utilization = None
        gpu.append({"device": card.name, "utilizationPercent": utilization})
    return {"load": list(os.getloadavg()), "cpus": len(os.sched_getaffinity(0)),
            "memoryAvailable": mem["MemAvailable"], "memoryTotal": mem["MemTotal"],
            "diskFree": partitions.free, "diskTotal": partitions.total, "gpus": gpu}


def read_regular(path, limit):
    if path.parent.is_symlink():
        return None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as file:
            details = os.fstat(file.fileno())
            if stat.S_ISREG(details.st_mode) and details.st_size <= limit and details.st_nlink == 1:
                data = file.read(limit + 1)
                if len(data) <= limit:
                    return data
    except OSError:
        return None
    return None


def get_json(path):
    data = read_regular(path, MAX_REPORT_BYTES + 1)
    try:
        def invalid_number(_value):
            raise ValueError("Invalid JSON number")
        result = json.loads(data, parse_constant=invalid_number) if data else None
        json.dumps(result, allow_nan=False)
        return result
    except (ValueError, RecursionError):
        return None


def terminate(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=2)
    except ProcessLookupError:
        pass
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


class Worker:
    def __init__(self, store, project_root, concurrency, min_ram, min_disk, retain_days):
        self.store = store
        self.root = project_root
        self.concurrency = concurrency
        self.min_ram = min_ram
        self.min_disk = min_disk
        self.retain_days = retain_days
        self.stop = threading.Event()
        self.sandbox = ScopedSandbox()

    def run(self):
        with (self.store.data / "worker.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                raise RuntimeError("An automation worker already owns this queue") from error
            self.store.interrupt()
            for directory in self.store.scratch.iterdir():
                if directory.is_dir():
                    shutil.rmtree(directory)
            with tempfile.TemporaryDirectory(dir=self.store.scratch) as directory:
                probe = Path(directory)
                for sub in ("tmp", "home"):
                    (probe / sub).mkdir(mode=0o700)
                process = self.sandbox.start(probe, ["probe"])
                try:
                    if process.wait(timeout=10) != 0:
                        raise RuntimeError("Bubblewrap sandbox could not start with the required restrictions")
                except subprocess.TimeoutExpired as error:
                    terminate(process)
                    raise RuntimeError("Bubblewrap sandbox did not start in time") from error
            signal.signal(signal.SIGTERM, lambda *_: self.stop.set())
            signal.signal(signal.SIGINT, lambda *_: self.stop.set())
            next_sample = 0
            next_cleanup = 0
            admitted = False
            with concurrent.futures.ThreadPoolExecutor(max_workers=self.concurrency) as pool:
                running = set()
                while not self.stop.is_set():
                    now = time.monotonic()
                    if now >= next_sample:
                        metrics = resources(self.store.data)
                        admitted = (metrics["memoryAvailable"] >= self.min_ram
                                    and metrics["diskFree"] >= self.min_disk
                                    and metrics["load"][0] < metrics["cpus"] * 1.5)
                        self.store.heartbeat({**metrics, "admittingJobs": admitted, "parallelJobs": self.concurrency})
                        next_sample = now + HEARTBEAT_INTERVAL
                    if now >= next_cleanup:
                        self.prune()
                        next_cleanup = now + 3600
                    complete = {future for future in running if future.done()}
                    for future in complete:
                        future.result()
                    running -= complete
                    while admitted and len(running) < self.concurrency and (job := self.store.claim()):
                        running.add(pool.submit(self.execute, job))
                    self.stop.wait(SAMPLE_INTERVAL)
            self.store.interrupt()
            with self.store.connect(write=True) as db:
                db.execute("DELETE FROM worker WHERE id=1")

    def prune(self):
        cutoff = time.time() - self.retain_days * 86400
        for entry in self.store.results.iterdir():
            if entry.is_dir() and entry.stat().st_mtime < cutoff:
                shutil.rmtree(entry)

    def track(self, process, job, scratch, deadline):
        previous = None
        try:
            while True:
                if self.stop.is_set():
                    raise JobStopped("Worker stopped")
                if self.store.state(job) == "cancelling":
                    raise JobStopped("Cancellation requested")
                if time.monotonic() >= deadline:
                    raise TimeoutError("Tool exceeded its wall-clock limit")
                if shutil.disk_usage(self.store.data).free < self.min_disk // 2:
                    raise RuntimeError("Tool stopped to preserve the server disk reserve")
                status = get_json(scratch / "progress.json")
                if (isinstance(status, dict) and status != previous and type(status.get("percent")) is int
                        and 0 <= status["percent"] < 100 and isinstance(status.get("message"), str)):
                    self.store.update(job, {"percent": status["percent"], "message": status["message"][:250]})
                    previous = status
                try:
                    return process.wait(timeout=SAMPLE_INTERVAL)
                except subprocess.TimeoutExpired:
                    continue
        finally:
            if process.poll() is None:
                terminate(process)

    def execute(self, job):
        key, tool = job["id"], job["tool"]
        scratch = self.store.scratch / key
        state, message, report, artifacts = "failed", "Tool could not complete", None, []
        try:
            if job["revision"] != revision() or job["version"] != TOOLS[tool]["version"]:
                raise RuntimeError("Registered tool changed after submission. Queue a new job.")
            _, objects, object_format = select_project(self.root, job["project"], job["commit"])
            for sub in ("tmp", "home"):
                (scratch / sub).mkdir(parents=True, mode=0o700)
            deadline = time.monotonic() + TOOLS[tool]["timeoutSeconds"]
            process = self.sandbox.start(scratch, ["prepare", job["commit"], object_format,
                                                 "1" if TOOLS[tool]["snapshot"] else "0"], objects=objects)
            code = self.track(process, key, scratch, deadline)
            if code == 0:
                shutil.rmtree(scratch / "git")
                (scratch / "request.json").write_text(json.dumps({"tool": tool, "inputs": job["inputs"]}))
                (scratch / "source").mkdir(exist_ok=True)
                process = self.sandbox.start(scratch, ["run"], tool=tool)
                code = self.track(process, key, scratch, deadline)
            result = get_json(scratch / "result.json")
            if isinstance(result, dict) and isinstance(result.get("report"), dict):
                report = result["report"]
                if code == 0 and result.get("ok") is True:
                    state, message = "succeeded", "Completed"
                else:
                    message = "Tool reported an error or failed check"
            else:
                message = f"Execution failed before producing a report (exit {code})"
        except JobStopped as error:
            state, message = "interrupted", str(error)
        except (OSError, RuntimeError, ValueError) as error:
            report = {"error": str(error)[:500]}
        except Exception:
            report = {"error": "Could not prepare or execute the registered tool"}
        finally:
            for name in TOOLS.get(tool, {}).get("artifacts", []):
                data = read_regular(scratch / "artifacts" / name, 1024 * 1024)
                if data is None:
                    continue
                try:
                    target = self.store.results / key / name
                    target.parent.mkdir(exist_ok=True, mode=0o700)
                    target.write_bytes(data)
                    artifacts.append({"name": name, "bytes": len(data)})
                except OSError:
                    state, message = "failed", "Could not retain tool evidence"
            shutil.rmtree(scratch, ignore_errors=True)
            self.store.finish(key, state, message, report, artifacts)
