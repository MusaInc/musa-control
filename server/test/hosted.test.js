import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createProviders } from '../src/providers.js';
import { createAgents } from '../src/agents.js';
import { openDb } from '../src/db.js';
import { createAuth } from '../src/auth.js';

test('hosted jobs fail closed without ChatGPT login and ignore saved API keys', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mc-hosted-'));
  try {
    const bin = path.join(dir, 'codex');
    fs.writeFileSync(bin, '#!/bin/sh\necho "Not logged in" >&2\nexit 1\n', {mode: 0o755});
    fs.writeFileSync(path.join(dir, 'provider-keys.json'), JSON.stringify({codex: 'sk-' + 'x'.repeat(40)}));
    const cfg = {hosted: true, dataDir: dir, codexBinary: bin, codexSessionsDir: dir, claudeProjectsDir: dir, geminiDir: dir};
    const providers = createProviders(cfg, {emit() {}});
    assert.equal((await providers.list({fresh:true}))[0].auth.signedIn, false);
    assert.deepEqual(providers.envFor('codex'), {});
    await assert.rejects(providers.setKey('codex', 'sk-' + 'x'.repeat(40)), {status: 403});
    await assert.rejects(providers.startLogin('claude'), {status: 403});
    const db = openDb(cfg);
    try {
      const agents = createAgents(cfg, db, {get() { throw Error('Must not launch'); }}, {});
      await assert.rejects(agents.launch({agent:'codex',project:'test'}), {status:409});
      await assert.rejects(agents.launch({agent:'claude',project:'test'}), {status:403});
      fs.writeFileSync(bin, '#!/bin/sh\necho "Logged in using an API key"\n');
      await assert.rejects(agents.launch({agent:'codex',project:'test'}), {status:409});
    } finally { db.close(); }
  } finally { fs.rmSync(dir, {recursive:true,force:true}); }
});

test('separate tenant databases reject foreign tokens, expired codes and CLI-revoked cookies', async () => {
  const dirs = [0,1].map(() => fs.mkdtempSync(path.join(os.tmpdir(),'mc-tenant-')));
  const dbs = dirs.map(dataDir => openDb({dataDir}));
  try {
    const auths = dbs.map(db => createAuth({deviceTokenDays:90},db));
    const owner = auths[0].issue('owner','test');
    assert.equal(auths[1].authenticate({headers:{authorization:`Bearer ${owner.token}`}}), null);
    const expired = auths[1].createPairCode(-1);
    assert.equal((await auths[1].pair({code:expired.code},'test')).status,401);
    const code = auths[1].createPairCode().code;
    const paired = await auths[1].pair({code},'test');
    assert.equal(paired.status,200);
    assert.equal((await auths[1].pair({code},'test')).status,401);
    const device = auths[1].authenticate({headers:{authorization:`Bearer ${paired.body.token}`}});
    const cookie = auths[1].issueWebCookie(device);
    const req = {headers:{cookie:`${cookie.name}=${cookie.value}`}};
    assert.ok(auths[1].authenticate(req,{allowCookie:true}));
    // A separate administrator process revokes directly through the shared DB.
    dbs[1].raw.prepare('UPDATE devices SET revoked=1 WHERE id=?').run(device.id);
    assert.equal(auths[1].authenticate(req,{allowCookie:true}),null);
  } finally { dbs.forEach(db => db.close()); dirs.forEach(dir => fs.rmSync(dir,{recursive:true,force:true})); }
});
