// Run as root with Node 22+. No credential values are printed or written.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {execFileSync, spawnSync} from 'node:child_process';
import {createRequire} from 'node:module';
const require = createRequire(new URL('../../server/package.json', import.meta.url));
const WebSocket = require('ws');
const docker = (...args) => execFileSync('docker',args,{encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim();
const inside = (...args) => docker('exec','musa-hafsa',...args);
try { fs.unlinkSync('/var/lib/musa-tenants/hafsa/security-passed'); } catch (e) { if(e.code !== 'ENOENT') throw e; }
const base = process.env.HAFSA_TEST_URL || 'http://127.0.0.1:8171';
const ok = (s) => console.log('PASS '+s);
const inspect = JSON.parse(docker('inspect','musa-hafsa'))[0];
const h=inspect.HostConfig;
assert.equal(inspect.Config.User,'11001:11001');
assert.equal(h.Privileged,false); assert.equal(h.ReadonlyRootfs,true);
assert.deepEqual(h.CapDrop,['ALL']); assert.ok(h.SecurityOpt.includes('no-new-privileges:true'));
assert.equal(h.Memory,1536*1024*1024);assert.equal(h.MemorySwap,h.Memory);assert.equal(h.NanoCpus,1e9);assert.equal(h.PidsLimit,256);
assert.equal(h.PidMode,'');assert.notEqual(h.NetworkMode,'host');
assert.equal(inspect.Mounts.length,1);assert.equal(inspect.Mounts[0].Source,'/var/lib/musa-tenants/hafsa/home');
assert.equal(inspect.Mounts[0].Destination,'/home/hafsa');
assert.equal(h.PortBindings['8170/tcp'][0].HostIp,'127.0.0.1');
assert.ok(!inspect.Config.Env.some(e=>/^(OPENAI_API_KEY|SSH_AUTH_SOCK|AWS_|ANTHROPIC_API_KEY|GH_TOKEN|GITHUB_TOKEN)=/.test(e)));
ok('unprivileged, read-only container, sole tenant mount, loopback-only port, no inherited credentials');
assert.equal(inside('cat','/sys/fs/cgroup/memory.max'),'1610612736');
assert.equal(inside('cat','/sys/fs/cgroup/memory.swap.max'),'0');
assert.equal(inside('cat','/sys/fs/cgroup/pids.max'),'256');
assert.equal(inside('cat','/sys/fs/cgroup/cpu.max'),'100000 100000');
assert.match(inside('cat','/sys/fs/cgroup/io.max'),/7:\d+ rbps=20971520 wbps=10485760/);
ok('kernel enforces CPU, RAM, zero swap, PID and disk I/O limits');
inside('sh','-c','test ! -e /home/abdul && test ! -e /var/run/docker.sock && test ! -e /root/.ssh && test ! -e /home/hafsa/.ssh');
assert.throws(()=>inside('sh','-c','touch /etc/escape-test'));
assert.throws(()=>inside('sh','-c','mount -t tmpfs tmpfs /mnt'));
ok('owner home, SSH keys, Docker socket, root writes and mounts unavailable');
for(const target of ['http://172.30.47.1:22','http://159.195.109.68:443','http://100.110.157.74:22','http://169.254.169.254','http://10.0.0.1','http://172.17.0.1:2375','http://192.168.1.1','http://[::1]:22']) {
  assert.throws(()=>inside('curl','-fsS','--connect-timeout','2','--max-time','3',target));
}
inside('curl','-fsS','--max-time','20','https://registry.npmjs.org/-/ping');
ok('host/public-IP, private LAN, other Docker networks and metadata denied; public HTTPS works');
// fallocate reserves blocks without writing gigabytes. It must fail above the hard filesystem size.
const quota=spawnSync('docker',['exec','musa-hafsa','fallocate','-l','11G','/home/hafsa/quota-probe'],{encoding:'utf8'});
assert.notEqual(quota.status,0);assert.match(quota.stderr,/No space left/);
inside('rm','-f','/home/hafsa/quota-probe');
ok('11 GiB allocation rejected by fixed 10 GiB filesystem');
const unsigned=await fetch(base+'/api/projects');assert.equal(unsigned.status,401);
const issued=JSON.parse(inside('node','--no-warnings','/opt/musa/bin/musa-companion.js','pair','--json'));
async function api(method,path,body,token) {
 const r=await fetch(base+path,{method,headers:{...(token?{Authorization:`Bearer ${token}`} : {}),...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined});
 return {status:r.status,body:await r.json()};
}
const paired=await api('POST','/api/pair',{code:issued.code,deviceName:'Isolation verification (revoked after test)'});
assert.equal(paired.status,200);const token=paired.body.token,id=paired.body.deviceId;
try {
 assert.equal((await api('POST','/api/pair',{code:issued.code})).status,401);
 assert.equal((await api('GET','/api/me',null,'mc_invalid')).status,401);
 const me=await api('GET','/api/me',null,token);assert.equal(me.body.server.user,'hafsa');
 assert.equal((await fetch('http://127.0.0.1:8160/api/projects',{headers:{Authorization:`Bearer ${token}`}})).status,401);
 ok('single-use pairing, unsigned/invalid token rejection and rejection by personal gateway');
 const providers=await api('GET','/api/providers?fresh=1',null,token);
 assert.equal(providers.status,200);assert.equal(providers.body.length,1);assert.equal(providers.body[0].subscriptionOnly,true);assert.equal(providers.body[0].auth.signedIn,false);
 assert.equal((await api('PUT','/api/providers/codex/key',{key:'sk-'+ 'x'.repeat(40)},token)).status,403);
 assert.equal((await api('POST','/api/agents',{agent:'codex',project:'missing',prompt:'Never sent to a model'},token)).status,409);
 assert.equal((await api('POST','/api/ssh/authorize',{publicKey:'invalid'},token)).status,403);
 ok('no Codex login, no API-key fallback, agent start blocked before authentication, SSH disabled');
 const wsbase=base.replace(/^http/,'ws');
 const foreign = new WebSocket(wsbase+'/api/terminal/ws?session=foreign-origin', {headers:{Authorization:`Bearer ${token}`,Origin:'https://untrusted.example'}});
 const denied = await new Promise((resolve,reject)=>{foreign.once('unexpected-response',(_,r)=>{r.resume();resolve(r.statusCode);foreign.terminate();});foreign.once('open',()=>{foreign.close();reject(Error('Foreign browser origin accepted'));});foreign.once('error',reject);});
 assert.equal(denied,403);ok('cross-origin browser WebSocket rejected');
 async function terminal(marker,command) {
   const ws=new WebSocket(wsbase+'/api/terminal/ws?session=security-check&cols=120&rows=36',{headers:{Authorization:`Bearer ${token}`}});
   await new Promise((resolve,reject)=>{let text='';const timeout=setTimeout(()=>{ws.terminate();reject(Error('Terminal timeout: '+text.slice(-1200)));},10000);ws.on('error',reject);ws.on('message',d=>{text+=d; if(text.includes(marker)){clearTimeout(timeout); resolve();}});ws.on('open',()=>setTimeout(()=>ws.send(Buffer.from(command+'\r')),200));});
   ws.close();return ws;
 }
 await terminal('FIRST_CONNECTION_OK','export HAFSA_RECONNECT=kept; printf "FIRST_CONNECTION_%s\\n" OK');
 await new Promise(r=>setTimeout(r,200));
 await terminal('RECONNECTED_kept','printf "RECONNECTED_%s\\n" "$HAFSA_RECONNECT"');
 ok('authenticated WebSocket terminal reconnects to same persistent tmux shell');
 inside('sh','-c','printf persistence > /home/hafsa/.verification-persistence');
 execFileSync('systemctl',['restart','musa-hafsa'],{stdio:'pipe'});
 for(let i=0;i<60;i++){try{if((await api('GET','/api/me',null,token)).status===200)break;}catch{}await new Promise(r=>setTimeout(r,250));}
 assert.equal((await api('GET','/api/me',null,token)).status,200);assert.equal(inside('cat','/home/hafsa/.verification-persistence'),'persistence');inside('rm','/home/hafsa/.verification-persistence');
 ok('service restart preserves project storage and paired device authentication');
 const ws=new WebSocket(wsbase+'/api/terminal/ws?session=revocation-check',{headers:{Authorization:`Bearer ${token}`}});
 await new Promise((resolve,reject)=>{ws.once('open',resolve);ws.once('error',reject);});
 const closed=new Promise((resolve,reject)=>{const timer=setTimeout(()=>{ws.terminate();reject(Error('Revoked terminal stayed open'));},5000);ws.once('close',code=>{clearTimeout(timer);resolve(code);});});
 inside('node','--no-warnings','/opt/musa/bin/musa-companion.js','revoke',id);
 assert.equal(await closed,4401);assert.equal((await api('GET','/api/me',null,token)).status,401);
 ok('administrator revocation invalidates live terminal and REST token');
} finally {
 inside('node','--no-warnings','/opt/musa/bin/musa-companion.js','revoke',id);
 for(const name of ['security-check','revocation-check']) {try{inside('tmux','kill-session','-t',name);}catch{}}
}
fs.writeFileSync('/var/lib/musa-tenants/hafsa/security-passed', `${inspect.Id} ${inspect.Image}\n${new Date().toISOString()}\n`, {mode:0o600});
console.log('SECURITY CHECKS PASSED; verification device revoked. No invitation credential issued.');
