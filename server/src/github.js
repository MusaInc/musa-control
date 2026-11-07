// GitHub through the already-authenticated `gh` CLI on the VPS. No token is
// handled or stored by Musa Control. Results are cached briefly so many
// open panels don't hammer the API.
import { run } from "./exec.js";

const REPO = /^[\w.-]+\/[\w.-]+$/;
const check = (repo) => { if (!REPO.test(repo)) throw Object.assign(new Error("Bad repository"), { status: 400 }); return repo; };

export function createGithub(events) {
  const cache = new Map();
  async function gh(args, { ttl = 20_000, timeout = 30_000 } = {}) {
    const key = args.join("\u0000");
    const c = cache.get(key);
    if (ttl && c && Date.now() - c.at < ttl) return c.value;
    const r = await run("gh", args, { timeout, maxBuffer: 64 * 1024 * 1024 });
    if (r.code !== 0) throw Object.assign(new Error((r.stderr || r.error || "gh failed").trim().slice(0, 800)), { status: 502 });
    const value = r.stdout.trim().startsWith("{") || r.stdout.trim().startsWith("[") ? JSON.parse(r.stdout) : r.stdout;
    if (ttl) cache.set(key, { at: Date.now(), value });
    return value;
  }

  const RUN_FIELDS = "databaseId,displayTitle,status,conclusion,workflowName,headBranch,headSha,event,createdAt,updatedAt,url,number,attempt";
  const runs = (repo, limit = 20) => gh(["run", "list", "-R", check(repo), "-L", String(limit), "--json", RUN_FIELDS]);
  const runDetail = (repo, id) => gh(["run", "view", String(+id), "-R", check(repo), "--json", RUN_FIELDS + ",jobs"], { ttl: 5000 });
  async function runLog(repo, id, { failedOnly = true } = {}) {
    const args = ["run", "view", String(+id), "-R", check(repo), failedOnly ? "--log-failed" : "--log"];
    const r = await run("gh", args, { timeout: 60_000, maxBuffer: 128 * 1024 * 1024 });
    const text = r.stdout || r.stderr;
    // Keep the tail: that's where the failure is.
    return { text: text.length > 400_000 ? text.slice(-400_000) : text, truncated: text.length > 400_000 };
  }
  async function rerun(repo, id, { failed = true } = {}) {
    await gh(["run", "rerun", String(+id), "-R", check(repo), ...(failed ? ["--failed"] : [])], { ttl: 0 });
    cache.clear();
    events.emit({ kind: "ci.rerun", title: `Re-ran ${failed ? "failed jobs of " : ""}run ${id} on ${repo}`, detail: { repo, run: +id } });
    return { ok: true };
  }
  async function cancel(repo, id) {
    await gh(["run", "cancel", String(+id), "-R", check(repo)], { ttl: 0 });
    cache.clear();
    events.emit({ kind: "ci.cancel", title: `Cancelled run ${id} on ${repo}`, detail: { repo, run: +id } });
    return { ok: true };
  }
  const workflows = (repo) => gh(["workflow", "list", "-R", check(repo), "--json", "id,name,path,state"], { ttl: 120_000 });
  async function dispatch(repo, workflow, inputs = {}) {
    if (!/^[\w.-]+\.ya?ml$|^\d+$/.test(String(workflow))) throw Object.assign(new Error("Bad workflow"), { status: 400 });
    const args = ["workflow", "run", String(workflow), "-R", check(repo)];
    for (const [k, v] of Object.entries(inputs)) { if (!/^[\w-]+$/.test(k)) continue; args.push("-f", `${k}=${String(v).slice(0, 200)}`); }
    await gh(args, { ttl: 0 });
    cache.clear();
    events.emit({ kind: "ci.dispatch", title: `Started workflow ${workflow} on ${repo}`, detail: { repo, workflow, inputs } });
    return { ok: true };
  }
  const prs = (repo) => gh(["pr", "list", "-R", check(repo), "-s", "all", "-L", "20", "--json", "number,title,state,headRefName,baseRefName,author,updatedAt,url,isDraft,reviewDecision,additions,deletions"]);
  const prDiff = async (repo, n) => ({ diff: String(await gh(["pr", "diff", String(+n), "-R", check(repo)], { ttl: 30_000 })) });
  const prView = (repo, n) => gh(["pr", "view", String(+n), "-R", check(repo), "--json", "number,title,body,state,headRefName,baseRefName,author,updatedAt,url,isDraft,reviewDecision,additions,deletions,files,commits,statusCheckRollup"]);

  // Watch recent runs of the given repos and emit finish events (with notifications).
  const known = new Map();
  async function watch(repos) {
    for (const repo of repos) {
      let list;
      try { list = await runs(repo, 10); } catch { continue; }
      for (const r of list) {
        const k = `${repo}#${r.databaseId}#${r.attempt}`, prev = known.get(k);
        if (prev && prev !== "completed" && r.status === "completed") {
          events.emit({ kind: "ci.finished", title: `${r.workflowName} ${r.conclusion} on ${repo.split("/")[1]} (${r.headBranch})`,
            detail: { repo, run: r.databaseId, conclusion: r.conclusion, url: r.url, follow: { view: "ci", repo, run: r.databaseId } }, notify: true, dedupe: `ci:${k}:done` });
        }
        known.set(k, r.status);
      }
    }
  }
  return { runs, runDetail, runLog, rerun, cancel, workflows, dispatch, prs, prDiff, prView, watch };
}
