// Private local credentials stay in the host's protected configuration.
import fs from 'node:fs';
import {createPrivateKey,sign} from 'node:crypto';
const home=process.env.MUSA_OWNER_HOME || '/home/abdul';
const env=Object.fromEntries(fs.readFileSync(process.env.ASC_ENV_FILE || `${home}/.config/reso/asc-api.env`,'utf8').split('\n').filter(l=>/^[A-Z_]+=/.test(l)).map(l=>[l.slice(0,l.indexOf('=')),l.slice(l.indexOf('=')+1).trim()]));
const b64=o=>Buffer.from(JSON.stringify(o)).toString('base64url');
function token(){const now=Math.floor(Date.now()/1000);const h=b64({alg:'ES256',kid:env.EXPO_ASC_KEY_ID,typ:'JWT'}),p=b64({iss:env.EXPO_ASC_ISSUER_ID,iat:now,exp:now+600,aud:'appstoreconnect-v1'});const key=createPrivateKey(fs.readFileSync(env.EXPO_ASC_API_KEY_PATH.replace(/^~/,home)));return `${h}.${p}.${sign('sha256',Buffer.from(`${h}.${p}`),{key,dsaEncoding:'ieee-p1363'}).toString('base64url')}`;}
export async function api(method,path,data){
 const r=await fetch('https://api.appstoreconnect.apple.com'+path,{method,headers:{Authorization:`Bearer ${token()}`,'Content-Type':'application/json'},body:data===undefined?undefined:JSON.stringify({data}),signal:AbortSignal.timeout(30000)});
 const text=await r.text();const result=text?JSON.parse(text):{};
 if(!r.ok)throw Object.assign(Error(`Apple ${method} ${path.split('?')[0]} HTTP ${r.status}: ${(result.errors||[]).map(e=>e.code+': '+e.title).join('; ')}`),{status:r.status,details:result.errors});
 return result;
}
