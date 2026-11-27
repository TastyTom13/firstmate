import json, os, subprocess, sys, copy
W, ROOT = sys.argv[1], sys.argv[2]
env = {k: v for k, v in os.environ.items() if not k.startswith(("FM_", "GH_", "GITHUB_"))}
env.update(GH_CONFIG_DIR=W+"/ghcfg", GH_TOKEN="fake-token", FM_HOME=W+"/home", GH_PROMPT_DISABLED="1", GH_NO_UPDATE_NOTIFIER="1")
S = "2d54f643"; OLD = "f48e92b4"
def R(i, wf, ev, concl, at, sha, branch="dev"): return dict(id=i, wf=wf, event=ev, conclusion=concl, at=at, sha=sha, branch=branch)
red = R(26328008555, 11, "push", "failure", "2026-05-23T10:00:00Z", OLD)
nightly = R(30000000001, 11, "schedule", "success", "2026-11-26T02:00:00Z", S)
failed = [["unit", "failure"], ["e2e (chrome, 1)", "timed_out"], ["lint", "success"]]
passed = [["unit", "success"], ["e2e (chrome, 1)", "success"], ["lint", "success"]]
def base():
    return dict(head=S, workflows={"11": "CI", "22": "Ping"}, runs=[copy.deepcopy(red), copy.deepcopy(nightly)],
                jobs={str(red["id"]): failed, str(nightly["id"]): passed})
def sh(script, *args):
    p = subprocess.run(["bash", script, *args], env=env, capture_output=True, text=True, timeout=90)
    return p.returncode, (p.stdout + p.stderr).strip()
cases = []
def case(name, want, mutate=lambda s: None):
    s = base(); mutate(s); cases.append((name, want, s))
def jobs(v): return lambda s: s["jobs"].__setitem__(str(nightly["id"]), v)
def run1(**kw): return lambda s: s["runs"][1].update(kw)
case("A reported Mentum shape: old red push, green nightly on head", "green")
def crowd(s): s["runs"] += [R(40000000000+i, 22, "schedule", "success", "2026-11-26T12:00:00Z", S) for i in range(120)]
case("B 120 newer runs of another workflow on head", "green", crowd)
case("C manual (workflow_dispatch) green run on head", "red", run1(event="workflow_dispatch"))
case("D nightly skipped a job that failed before", "red", jobs([["unit","success"],["e2e (chrome, 1)","skipped"]]))
case("E nightly lacks a job that failed before (renamed)", "red", jobs([["unit","success"],["e2e (1)","success"]]))
case("F nightly job list cannot be read", "red", lambda s: s["jobs"].pop(str(nightly["id"])))
case("G green nightly is on an older commit, not head", "red", run1(sha="aaaaaaaa"))
case("H branch head cannot be read", "red", lambda s: s.update(head=None))
case("I nightly on head failed after an earlier green one", "red", lambda s: s["runs"].append(R(30000000002,11,"schedule","failure","2026-11-27T02:00:00Z",S)))
case("J green nightly belongs to another workflow", "red", run1(wf=22))
case("K nightly on head was cancelled", "red", run1(conclusion="cancelled"))
case("L red push run is on the head itself", "red", lambda s: s["runs"][0].update(sha=S))
def keepgreen(s):
    s["runs"][0]["conclusion"]="success"; s["runs"][1]["conclusion"]="failure"
case("M old green push, red nightly on head", "green", keepgreen)
case("N only nightly runs exist, no push or PR run", "unknown", lambda s: s["runs"].pop(0))
def two(s):
    s["workflows"]["33"]="Deploy"; s["runs"].append(R(50000000001,33,"push","failure","2026-05-20T00:00:00Z",OLD)); s["jobs"]["50000000001"]=[["ship","failure"]]
case("O second workflow has an old red with no nightly", "red", two)
bad = 0
for name, want, s in cases:
    json.dump(s, open(W+"/scenario.json","w"))
    open(W+"/requests.log","w").close()
    nrc, new = sh(ROOT+"/bin/fm-base-green.sh", "mentum")
    reqs = open(W+"/requests.log").read()
    orc, old = sh(W+"/old/fm-base-green.sh", "mentum")
    ok = new.split()[0] == want and nrc == {"green":0,"red":1,"unknown":2}[want]
    bad += not ok
    print(f"== {name}\n   want {want} -> {'PASS' if ok else 'FAIL'}\n   before fix (exit {orc}): {old}\n   after  fix (exit {nrc}): {new}")
    if name.startswith("A "): open(W+"/requests-A.log","w").write(reqs)
json.dump(base(), open(W+"/scenario.json","w"))
env2 = dict(env, FM_BOOTSTRAP_NETWORK="only", FM_BOOTSTRAP_DETECT_ONLY="1")
for label, root_script in (("after", ROOT+"/bin/fm-bootstrap.sh"),):
    p = subprocess.run(["bash", root_script], env=env2, capture_output=True, text=True, timeout=120)
    print(f"== session-start digest, Mentum shape ({label} fix)\n   {p.stdout.strip()}")
    ok = "\nBOOTSTRAP_INFO: base branches: mentum green dev" in "\n"+p.stdout; bad += not ok
s = base(); s["jobs"][str(nightly["id"])] = [["unit","success"]]
json.dump(s, open(W+"/scenario.json","w"))
p = subprocess.run(["bash", ROOT+"/bin/fm-bootstrap.sh"], env=env2, capture_output=True, text=True, timeout=120)
print(f"== session-start digest, nightly lacks a failed job\n   {p.stdout.strip()}")
bad += "\nBASE_BRANCHES:" not in "\n"+p.stdout
print("failures:", bad)
