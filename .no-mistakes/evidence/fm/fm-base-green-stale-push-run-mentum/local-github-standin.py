import json, os, re, sys, socketserver
from http.server import BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
W = sys.argv[1]
def load(): return json.load(open(W + "/scenario.json"))
class H(BaseHTTPRequestHandler):
    def address_string(self): return "unix"
    def log_message(self, *a): pass
    def send(self, code, body):
        b = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urlparse(self.path); q = {k: v[0] for k, v in parse_qs(u.query).items()}
        open(W + "/requests.log", "a").write(self.path + "\n")
        m = re.match(r"^(?:/api/v3)?/repos/([^/]+)/([^/]+)/(.*)$", u.path)
        if not m: return self.send(404, {"message": "Not Found"})
        owner, rest = m[1], m[3]
        s = load(); repo = s.get("repos", {}).get(owner, s)
        def wf(i): return {"id": int(i), "name": repo["workflows"][str(i)], "state": "active", "path": ".github/workflows/w%s.yml" % i}
        def run(r): return {"id": r["id"], "name": repo["workflows"][str(r["wf"])], "workflow_id": r["wf"], "head_sha": r["sha"],
            "head_branch": r.get("branch", "dev"), "event": r["event"], "status": "completed", "conclusion": r["conclusion"],
            "created_at": r["at"], "updated_at": r["at"], "run_started_at": r["at"], "run_number": r["id"], "run_attempt": 1,
            "display_title": "t", "html_url": "https://github.com/o/r/actions/runs/%d" % r["id"],
            "jobs_url": "https://api.github.com/repos/o/r/actions/runs/%d/jobs" % r["id"],
            "head_commit": {"message": "m"}, "head_repository": {"owner": {"login": owner}, "name": "r"}}
        def runs(wid=None):
            out = [r for r in repo["runs"] if (wid is None or r["wf"] == int(wid))
                and ("branch" not in q or r.get("branch", "dev") == q["branch"])
                and ("event" not in q or r["event"] == q["event"])
                and ("head_sha" not in q or r["sha"] == q["head_sha"])]
            out.sort(key=lambda r: r["at"], reverse=True)
            n = int(q.get("per_page", 30)); p = int(q.get("page", 1))
            return self.send(200, {"total_count": len(out), "workflow_runs": [run(r) for r in out[(p-1)*n:p*n]]})
        if rest == "actions/runs": return runs()
        if rest == "actions/workflows":
            return self.send(200, {"total_count": len(repo["workflows"]), "workflows": [wf(i) for i in repo["workflows"]]})
        if x := re.match(r"actions/workflows/(\d+)/runs$", rest): return runs(x[1])
        if x := re.match(r"actions/workflows/(\d+)$", rest): return self.send(200, wf(x[1]))
        if x := re.match(r"actions/runs/(\d+)/jobs$", rest):
            jobs = repo["jobs"].get(x[1])
            if jobs is None: return self.send(500, {"message": "jobs unavailable"})
            return self.send(200, {"total_count": len(jobs), "jobs": [{"id": int(x[1])*100+i, "name": n, "status": "completed",
                "conclusion": c, "steps": [], "run_id": int(x[1]), "html_url": "u"} for i, (n, c) in enumerate(jobs)]})
        if x := re.match(r"actions/runs/(\d+)(?:/attempts/\d+)?$", rest):
            for r in repo["runs"]:
                if r["id"] == int(x[1]): return self.send(200, run(r))
        if x := re.match(r"branches/(.+)$", rest):
            if repo.get("head") is None: return self.send(404, {"message": "Branch not found"})
            return self.send(200, {"name": x[1], "commit": {"sha": repo["head"]}})
        return self.send(404, {"message": "Not Found"})
class S(socketserver.ThreadingMixIn, socketserver.UnixStreamServer): daemon_threads = True
S(W + "/gh.sock", H).serve_forever()
