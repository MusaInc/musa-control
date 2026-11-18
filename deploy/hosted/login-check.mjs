// Verify official device-login availability without completing login or printing codes.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
const run=(...a)=>execFileSync('docker',['exec','musa-hafsa',...a],{encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim();
const issued=JSON.parse(run('node','--no-warnings','/opt/musa/bin/musa-companion.js','token','--name','Login flow verification','--json'));
const base='https://hafsa.159-195-109-68.sslip.io';
async function api(method,p,body){const r=await fetch(base+p,{method,headers:{Authorization:`Bearer ${issued.token}`,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});const data=await r.json();assert.equal(r.status,200);return data;}
let name;
try{
 const login=await api('POST','/api/providers/codex/login',{});name=login.tmux;
 let ready=false;
 for(let i=0;i<30;i++){
  const state=await api('GET','/api/provider-sessions/'+name);
  ready=Boolean(state.deviceCode && state.urls?.some(u=>{try{return /(^|\.)(openai\.com|chatgpt\.com)$/.test(new URL(u).hostname);}catch{return false;}}));
  if(ready)break;
  await new Promise(r=>setTimeout(r,1000));
 }
 assert.ok(ready,'Official device login did not produce an OpenAI URL and code');
 console.log('PASS official OpenAI device-login URL and code available to the iPad; code not printed, login not completed');
}finally{
 if(name)await api('DELETE','/api/provider-sessions/'+name);
 run('node','--no-warnings','/opt/musa/bin/musa-companion.js','revoke',issued.deviceId);
}
