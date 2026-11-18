// Read-only TestFlight readiness report. Reuses a local Apple API credential;
// never prints credentials, tester identities, or invitation links.
import fs from 'node:fs';
import os from 'node:os';
import {createPrivateKey,sign} from 'node:crypto';
const env=Object.fromEntries(fs.readFileSync(process.env.ASC_ENV_FILE || `${os.homedir()}/.config/reso/asc-api.env`,'utf8').split('\n').filter(l=>/^[A-Z_]+=/.test(l)).map(l=>[l.slice(0,l.indexOf('=')),l.slice(l.indexOf('=')+1).trim()]));
const b64=o=>Buffer.from(JSON.stringify(o)).toString('base64url');
const now=Math.floor(Date.now()/1000), h=b64({alg:'ES256',kid:env.EXPO_ASC_KEY_ID,typ:'JWT'}), p=b64({iss:env.EXPO_ASC_ISSUER_ID,iat:now,exp:now+600,aud:'appstoreconnect-v1'});
const key=createPrivateKey(fs.readFileSync(env.EXPO_ASC_API_KEY_PATH.replace(/^~/,os.homedir())));
const sig=sign('sha256',Buffer.from(`${h}.${p}`),{key,dsaEncoding:'ieee-p1363'}).toString('base64url');
async function get(path){const r=await fetch('https://api.appstoreconnect.apple.com'+path,{headers:{Authorization:`Bearer ${h}.${p}.${sig}`}});if(!r.ok)throw Error(`Apple read failed: ${r.status}`);return r.json();}
const app=(await get('/v1/apps?filter[bundleId]=uk.co.musastudios.musacontrol')).data[0];if(!app)throw Error('Musa Control record missing');
const builds=await get(`/v1/builds?filter[app]=${app.id}&sort=-uploadedDate&limit=3&include=buildBetaDetail,preReleaseVersion`);
const related=new Map(builds.included.map(x=>[x.type+':'+x.id,x.attributes]));
console.log(JSON.stringify({app:app.attributes.name,builds:builds.data.map(b=>({build:b.attributes.version,processing:b.attributes.processingState,version:related.get('preReleaseVersions:'+b.relationships.preReleaseVersion.data.id)?.version,...related.get('buildBetaDetails:'+b.id)})),groups:(await get(`/v1/apps/${app.id}/betaGroups?limit=50`)).data.map(g=>({name:g.attributes.name,internal:g.attributes.isInternalGroup,publicLinkEnabled:g.attributes.publicLinkEnabled}))},null,2));
