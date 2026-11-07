// Git operations through the git CLI (existing credentials, no tokens here).
// Publishing operations (push) and history-rewriting ones are not exposed
// except push/pull, which the app gates behind an explicit confirmation.
import { run, must } from "./exec.js";

const GIT_ENV = { GIT_TERMINAL_PROMPT: "0", GIT_OPTIONAL_LOCKS: "0" };
const git = (cwd, args, opts = {}) => run("git", args, { cwd, env: GIT_ENV, timeout: 30_000, ...opts });
const gitMust = (cwd, args, opts = {}) => must("git", args, { cwd, env: GIT_ENV, timeout: 30_000, ...opts });

function parseStatus(out) {
  const res = { branch: null, upstream: null, ahead: 0, behind: 0, files: [] };
  for (const line of out.split("\n")) {
    if (line.startsWith("# branch.head ")) res.branch = line.slice(14);
    else if (line.startsWith("# branch.upstream ")) res.upstream = line.slice(18);
    else if (line.startsWith("# branch.ab ")) { const m = line.match(/\+(\d+) -(\d+)/); if (m) { res.ahead = +m[1]; res.behind = +m[2]; } }
    else if (line.startsWith("1 ") || line.startsWith("2 ")) {
      const parts = line.split(" ");
      const xy = parts[1];
      let p = parts.slice(line.startsWith("1 ") ? 8 : 9).join(" ");
      let from = null;
      if (line.startsWith("2 ")) { [p, from] = p.split("\t"); }
      res.files.push({ path: p, from, staged: xy[0] !== ".", unstaged: xy[1] !== ".", x: xy[0], y: xy[1] });
    } else if (line.startsWith("? ")) res.files.push({ path: line.slice(2), untracked: true, staged: false, unstaged: true, x: "?", y: "?" });
    else if (line.startsWith("u ")) res.files.push({ path: line.split(" ").slice(10).join(" "), conflict: true, staged: false, unstaged: true, x: "U", y: "U" });
  }
  return res;
}

export function createGit(projects, events) {
  async function status(id) {
    const p = projects.get(id);
    if (!p.git) return { git: false };
    const r = await git(p.path, ["status", "--porcelain=v2", "--branch", "-uall"]);
    if (r.code !== 0) return { git: true, error: r.stderr.trim() };
    const s = parseStatus(r.stdout);
    s.files = s.files.filter((f) => !projects.isSecret(f.path)).slice(0, 2000);
    return { git: true, ...s };
  }

  async function log(id, { limit = 50, file } = {}) {
    const p = projects.get(id);
    const args = ["log", `-n${Math.min(+limit || 50, 300)}`, "--date=iso-strict", "--pretty=format:%H%x1f%h%x1f%an%x1f%ad%x1f%s%x1f%D"];
    if (file) args.push("--", projects.resolveInside(id, file, { mustExist: false }).rel);
    const r = await git(p.path, args);
    return r.stdout.split("\n").filter(Boolean).map((l) => { const [sha, short, author, date, subject, refs] = l.split("\x1f"); return { sha, short, author, date, subject, refs }; });
  }

  async function diff(id, { file, staged = false, commit } = {}) {
    const p = projects.get(id);
    const args = commit ? ["show", "--format=%H%n%an%n%ad%n%s%n%b%x1e", "--stat=200", "-p", "--no-color", commit] : ["diff", "--no-color", "-U3"];
    if (!commit && staged) args.push("--cached");
    if (file) {
      const rel = projects.resolveInside(id, file, { mustExist: false }).rel;
      args.push("--", rel);
      if (!commit && !staged) {
        // Untracked files have no diff: show them as entirely added.
        const st = await git(p.path, ["ls-files", "--others", "--exclude-standard", "--", rel]);
        if (st.stdout.trim()) {
          const r = await git(p.path, ["diff", "--no-color", "--no-index", "--", "/dev/null", rel]);
          return { diff: r.stdout.slice(0, 3_000_000) };
        }
      }
    }
    if (commit && !/^[0-9a-f]{4,40}$/i.test(commit)) throw Object.assign(new Error("Bad commit id"), { status: 400 });
    const r = await git(p.path, args, { maxBuffer: 64 * 1024 * 1024 });
    return { diff: r.stdout.slice(0, 3_000_000), truncated: r.stdout.length > 3_000_000 };
  }

  async function branches(id) {
    const p = projects.get(id);
    const r = await git(p.path, ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)%x1f%(objectname:short)%x1f%(committerdate:iso-strict)%x1f%(upstream:short)%x1f%(HEAD)", "refs/heads", "refs/remotes"]);
    return r.stdout.split("\n").filter(Boolean).map((l) => { const [name, sha, date, upstream, head] = l.split("\x1f"); return { name, sha, date, upstream, current: head === "*" }; });
  }

  const relPaths = (id, paths) => (paths || []).map((f) => projects.resolveInside(id, f, { mustExist: false }).rel);

  async function stage(id, paths) { const p = projects.get(id); await gitMust(p.path, ["add", "--", ...relPaths(id, paths)]); return status(id); }
  async function unstage(id, paths) { const p = projects.get(id); await gitMust(p.path, ["restore", "--staged", "--", ...relPaths(id, paths)]); return status(id); }

  async function commit(id, message) {
    const p = projects.get(id);
    if (!String(message || "").trim()) throw Object.assign(new Error("Commit message required"), { status: 400 });
    await gitMust(p.path, ["commit", "-m", String(message)]);
    const [head] = await log(id, { limit: 1 });
    events.emit({ kind: "git.commit", project: id, title: `Committed ${head.short}: ${head.subject}`, detail: head });
    return head;
  }

  async function push(id) {
    const p = projects.get(id);
    const s = await status(id);
    const r = await git(p.path, s.upstream ? ["push"] : ["push", "-u", "origin", s.branch], { timeout: 120_000 });
    events.emit({ kind: "git.push", project: id, title: r.code === 0 ? `Pushed ${s.branch}` : `Push failed on ${s.branch}`, detail: { output: (r.stderr + r.stdout).slice(-4000), ok: r.code === 0 }, notify: r.code !== 0 });
    if (r.code !== 0) throw Object.assign(new Error((r.stderr || r.stdout).trim().slice(-2000)), { status: 422 });
    return { ok: true, output: (r.stderr + r.stdout).trim() };
  }

  async function pull(id) {
    const p = projects.get(id);
    const r = await git(p.path, ["pull", "--ff-only"], { timeout: 120_000 });
    if (r.code !== 0) throw Object.assign(new Error((r.stderr || r.stdout).trim().slice(-2000)), { status: 422 });
    events.emit({ kind: "git.pull", project: id, title: `Pulled (fast-forward)`, detail: { output: r.stdout.slice(-4000) } });
    return { ok: true, output: (r.stdout + r.stderr).trim() };
  }

  async function showFile(id, rel, ref = "HEAD") {
    const p = projects.get(id);
    if (!/^[\w./~^-]{1,80}$/.test(ref)) throw Object.assign(new Error("Bad ref"), { status: 400 });
    const r = projects.resolveInside(id, rel, { mustExist: false }).rel;
    const out = await git(p.path, ["show", `${ref}:${r}`], { maxBuffer: 32 * 1024 * 1024 });
    return out.code === 0 ? { text: out.stdout } : { text: null };
  }

  return { status, log, diff, branches, stage, unstage, commit, push, pull, showFile, parseStatus };
}
export { parseStatus };
