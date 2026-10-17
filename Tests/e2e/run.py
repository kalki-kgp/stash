#!/usr/bin/env python3
"""Drives a test build of Stash (./build.sh test) end to end against a scratch STASH_HOME.

Usage: Tests/e2e/run.py <path to stashctl> <scratch dir>
Copies go through the real system clipboard; the caller saves and restores it.
"""
import json, os, re, shutil, subprocess, sys, time

CTL, SCRATCH = sys.argv[1], sys.argv[2]
HOME = os.path.join(SCRATCH, "e2e-home")
DUMP = os.path.join(SCRATCH, "dump.json")
APP = os.path.join(os.path.dirname(__file__), "../../Stash.app/Contents/MacOS/Stash")

CMD, OPT, SHIFT = 1 << 20, 1 << 19, 1 << 17
RETURN, DOWN, UP, ESC, DELETE, P = 36, 125, 126, 53, 51, 35
DIGIT = {1: 18, 2: 19, 3: 20}
passed = failed = 0


def check(ok, msg):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
        print(f"  FAIL: {msg}")


def ctl(*args):
    subprocess.run([CTL, *args], check=True)
    time.sleep(0.15)


def key(code, flags=0, chars=""):
    ctl(f"key:{code}:{flags}:{chars}")


def dump():
    if os.path.exists(DUMP):
        os.remove(DUMP)
    ctl(f"dump:{DUMP}")
    for _ in range(40):
        if os.path.exists(DUMP):
            return json.load(open(DUMP))
        time.sleep(0.05)
    raise RuntimeError("no dump")


def copy(text):
    subprocess.run(["pbcopy"], input=text.encode(), check=True)
    time.sleep(0.8)  # the watcher polls every 0.5 s


def clipboard():
    return subprocess.run(["pbpaste"], capture_output=True).stdout.decode()


def footprint(pid):
    out = subprocess.run(["footprint", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint: ([\d.]+) (KB|MB|GB)", out)
    v = float(m.group(1))
    return v / 1024 if m.group(2) == "KB" else v * 1024 if m.group(2) == "GB" else v


shutil.rmtree(HOME, ignore_errors=True)
env = dict(os.environ, STASH_HOME=HOME, MallocStackLogging="1")
proc = subprocess.Popen([APP], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
pid = proc.pid
try:
    print("• launch + Maccy import")
    for _ in range(120):
        time.sleep(0.5)
        if os.path.exists(os.path.join(HOME, ".maccy-imported")):
            break
    time.sleep(1)
    ctl("open")
    d = dump()
    check(d["rowCount"] > 0, f"imported history shows in the panel ({d['rowCount']} rows on first page)")
    check(d["hotKey"], "⌘⇧C registered")
    ctl("close")
    print(f"  footprint after import: {footprint(pid):.0f} MB")
    check(footprint(pid) < 60, "import leaves the app under 60 MB (images decoded in the child process)")

    print("• live capture")
    marker = f"e2e-{int(time.time())}"
    copy(f"{marker} first")
    copy(f"{marker} second")
    copy(f"{marker} third")
    ctl("open")
    d = dump()
    check([r["preview"] for r in d["rows"][:3]] == [f"{marker} third", f"{marker} second", f"{marker} first"], "newest copies on top, in order")
    check(d["selected"] == 0, "first row selected on open")
    check(d["visible"] and d["key"], "panel is visible and takes keys")

    print("• keyboard: arrows, return, ⌘n, esc")
    key(DOWN, chars=""); key(DOWN, chars=""); key(UP, chars="")
    check(dump()["selected"] == 1, "↓↓↑ lands on row 2")
    key(RETURN, chars="\r")
    time.sleep(0.3)
    check(clipboard() == f"{marker} second", "↩ copies the selected row")
    check(not dump()["visible"], "panel closes after picking")
    time.sleep(0.8)
    ctl("open")
    d = dump()
    check(d["rows"][0]["preview"] == f"{marker} second", "picked item moves to the top")
    check(sum(1 for r in d["rows"] if r["preview"] == f"{marker} second") == 1, "picking doesn't create a duplicate")
    key(DIGIT[3], CMD, "3")
    time.sleep(0.3)
    check(clipboard() == f"{marker} first", "⌘3 copies row 3")
    ctl("open")
    key(ESC, chars="ESC")
    time.sleep(0.3)
    check(not dump()["visible"], "esc closes the panel")

    print("• search")
    ctl("open")
    ctl(f"type:{marker}")
    d = dump()
    check(d["query"] == marker, "typing goes into the search field")
    check(d["rowCount"] == 3 and all(marker in r["preview"] for r in d["rows"]), "search filters to the 3 matches")
    ctl("type: thrd")
    d = dump()
    check(d["rowCount"] >= 1 and d["rows"][0]["preview"] == f"{marker} third", "fuzzy: 'thrd' finds 'third'")
    key(ESC, chars="ESC")
    ctl("open")
    check(dump()["query"] == "", "search is cleared when the panel reopens")

    print("• pin, delete, clear (Maccy keys)")
    key(DOWN, chars="")
    key(P, OPT, "π")
    d = dump()
    pinned = d["rows"][0]
    check(pinned["pinned"] and pinned["preview"] == f"{marker} second", "⌥P pins and moves the row to the top")
    key(DOWN, chars="")
    before = dump()["rowCount"]
    victim = dump()["rows"][1]["preview"]
    key(DELETE, OPT)
    d = dump()
    check(victim not in [r["preview"] for r in d["rows"]], "⌥⌫ deletes the selected row")
    key(DELETE, OPT | CMD)
    d = dump()
    check([r["preview"] for r in d["rows"]] == [f"{marker} second"], "⌥⌘⌫ clears all but pinned")
    key(DELETE, OPT | CMD | SHIFT)
    check(dump()["rowCount"] == 0, "⇧⌥⌘⌫ clears everything")
    key(ESC, chars="ESC")

    print("• pause / ignore next")
    ctl("pause:1")
    copy(f"{marker} while paused")
    ctl("pause:0")
    ctl("ignorenext")
    copy(f"{marker} ignored once")
    copy(f"{marker} after ignore")
    ctl("open")
    previews = [r["preview"] for r in dump()["rows"]]
    check(f"{marker} while paused" not in previews, "paused copies aren't saved")
    check(f"{marker} ignored once" not in previews, "⌥⇧-click skips exactly the next copy")
    check(f"{marker} after ignore" in previews, "capture resumes after that")
    ctl("close")

    print("• image capture")
    shot = os.path.join(SCRATCH, "imgtest/orig.tiff")
    if os.path.exists(shot):
        fp_before = footprint(pid)
        subprocess.run(["osascript", "-e", f'set the clipboard to (read (POSIX file "{shot}") as TIFF picture)'], check=True)
        time.sleep(3)
        ctl("open")
        d = dump()
        check(d["rows"][0]["kind"] == 1, "26 MB screenshot captured as an image")
        ctl("close")
        time.sleep(0.5)
        grew = footprint(pid) - fp_before
        print(f"  footprint after 26 MB image: +{grew:.0f} MB")
        check(grew < 45, "image copy costs the app < 45 MB (the pasteboard read itself)")

    print("• open speed (⌘⇧C → panel drawn)")
    for i in range(20):
        copy(f"{marker} speed {i}")
    times = []
    for _ in range(15):
        ctl("hotkey")
        times.append(dump()["openMs"])
        ctl("hotkey")
    times.sort()
    print(f"  open: median {times[len(times)//2]:.1f} ms, worst {times[-1]:.1f} ms")
    check(times[len(times) // 2] < 30, "median open under 30 ms")

    print("• stress: 300 open/search/close cycles")
    base = footprint(pid)
    lk = subprocess.run(["leaks", str(pid)], capture_output=True, text=True).stdout
    leaks_before = int(re.search(r"(\d+) leaks? for", lk).group(1))
    for i in range(300):
        ctl("hotkey") if i % 2 else ctl("open")
        if i % 3 == 0:
            ctl(f"type:{marker[:4]}")
        if i % 5 == 0:
            key(DOWN, chars="")
        ctl("close")
    time.sleep(1)
    end = footprint(pid)
    print(f"  footprint {base:.0f} → {end:.0f} MB")
    check(end - base < 10, "no memory growth across 300 cycles")
    leaks = subprocess.run(["leaks", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"(\d+) leaks? for (\d+) total leaked bytes", leaks)
    print("  leaks:", m.group(0) if m else "?")
    # macOS 26's AppIntents leaks a few NSXPCConnection cycles (~14 KB) once at launch in every app
    # built against that SDK (Buds.app shows the same). With stack logging on, any leak allocated from
    # Stash's own code has a frame from the Stash binary in its stack.
    stacks = subprocess.run(["leaks", "--fullStacks", str(pid)], capture_output=True, text=True).stdout
    ours = [l.strip() for l in stacks.splitlines() if re.match(r"^\s*\d+\s+Stash\s+0x", l)]
    check(not ours, f"no leaked allocation comes from Stash's code ({ours[:3]})")
    check(m and int(m.group(1)) <= leaks_before, f"leak count doesn't grow with use ({leaks_before} → {m.group(1) if m else '?'})")
    check(m and int(m.group(2)) < 20000, "leaked bytes stay at the launch-time ~14 KB")
    check(proc.poll() is None, "app still running")
finally:
    proc.terminate()
    proc.wait(timeout=5)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
