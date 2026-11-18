// Explicitly authorized: invite Hafsa only after Apple approves build 116.
// Never creates or sends a workspace pairing credential.
import fs from 'node:fs';import crypto from 'node:crypto';import {execFileSync} from 'node:child_process';
import {api} from './asc-client.mjs';import {canInvite} from './beta-release-policy.mjs';
const dir=process.env.MUSA_RELEASE_STATE || '/var/lib/musa-beta-release';
const config=JSON.parse(fs.readFileSync(dir+'/config.json'));
const stateFile=dir+'/state.json';
let state=fs.existsSync(stateFile)?JSON.parse(fs.readFileSync(stateFile)):{};
const save=()=>{fs.writeFileSync(stateFile+'.tmp',JSON.stringify(state,null,2),{mode:0o600});fs.renameSync(stateFile+'.tmp',stateFile);};
if(state.invitedAt){console.log('Already invited after approval; no repeat invitation.');process.exit(0);}
const app='6831994013',bid='b9d82af1-1de3-4765-8143-a014afadb398';
const submission=JSON.parse(fs.readFileSync('/home/abdul/.config/musa-hafsa/review-submission.json'));
const recipient=JSON.parse(fs.readFileSync('/home/abdul/.config/musa-hafsa/invitation.json'));
const email=recipient.email.toLowerCase().trim();
if(crypto.createHash('sha256').update(email).digest('hex')!==config.recipientHash)throw Error('Saved recipient changed; invitation held.');
const [a,b,v,beta,review,g,gb]=await Promise.all([
 api('GET',`/v1/apps/${app}`),api('GET',`/v1/builds/${bid}`),api('GET',`/v1/builds/${bid}/preReleaseVersion`),api('GET',`/v1/builds/${bid}/buildBetaDetail`),api('GET',`/v1/builds/${bid}/betaAppReviewSubmission`),api('GET',`/v1/betaGroups/${submission.groupId}`),api('GET',`/v1/betaGroups/${submission.groupId}/builds?limit=200`)]);
state.checkedAt=new Date().toISOString();state.reviewState=review.data.attributes.betaReviewState;state.externalState=beta.data.attributes.externalBuildState;save();
if(!canInvite({app:a.data,build:b.data,version:v.data,beta:beta.data,review:review.data,group:g.data,groupBuilds:gb.data})){console.log('Invitation held:',state.reviewState,state.externalState);process.exit(0);}
// Approval is necessary but not sufficient: require the verified workspace,
// current image/container, working TLS and authentication gate too.
const current=execFileSync('docker',['inspect','musa-hafsa','--format','{{.Id}} {{.Image}}'],{encoding:'utf8'}).trim();
if(fs.readFileSync('/var/lib/musa-tenants/hafsa/security-passed','utf8').split('\n')[0]!==current)throw Error('Workspace changed since security verification; invitation held.');
const url='https://hafsa.159-195-109-68.sslip.io';
if(!(await fetch(url+'/api/ping',{signal:AbortSignal.timeout(10000)})).ok || (await fetch(url+'/api/projects',{signal:AbortSignal.timeout(10000)})).status!==401)throw Error('Workspace readiness/auth check failed; invitation held.');
if(process.argv.includes('--dry-run')){console.log('Approved and ready; dry run sends nothing.');process.exit(0);}
const members=(await api('GET',`/v1/betaGroups/${submission.groupId}/betaTesters?limit=200`)).data;
const member=members.find(t=>t.attributes.email?.toLowerCase()===email);
if(state.invitationAttemptedAt){
 if(member){state.invitedAt=state.checkedAt;state.testerId=member.id;state.reconciled=true;save();console.log('Verified tester membership after prior attempt; no repeat invitation.');process.exit(0);}
 throw Error('Previous invitation attempt needs inspection; automatic resend withheld.');
}
if(member){state.invitedAt=state.checkedAt;state.testerId=member.id;state.alreadyMember=true;save();console.log('Hafsa already belongs to approved group; no duplicate invitation.');process.exit(0);}
const existing=(await api('GET',`/v1/betaTesters?filter[email]=${encodeURIComponent(email)}&limit=200`)).data.find(t=>t.attributes.email?.toLowerCase()===email);
state.invitationAttemptedAt=new Date().toISOString();save();
let tester;
if(existing){tester=existing;await api('POST',`/v1/betaGroups/${submission.groupId}/relationships/betaTesters`,[{type:'betaTesters',id:tester.id}]);}
else tester=(await api('POST','/v1/betaTesters',{type:'betaTesters',attributes:{email,firstName:'Hafsa',lastName:''},relationships:{betaGroups:{data:[{type:'betaGroups',id:submission.groupId}]}}})).data;
// Apple automatically emails when testers are added to a testable group.
// If notifications are explicitly off, send exactly one invitation ourselves.
if(beta.data.attributes.autoNotifyEnabled===false)await api('POST','/v1/betaTesterInvitations',{type:'betaTesterInvitations',relationships:{app:{data:{type:'apps',id:app}},betaTester:{data:{type:'betaTesters',id:tester.id}}}});
state.invitedAt=new Date().toISOString();state.testerId=tester.id;state.instructions='Build 116 What to Test contains full iPad setup steps; ask Abdul for a fresh code after installation.';save();
console.log('Hafsa invited to approved build 116 through TestFlight. Setup instructions are in What to Test. No pairing credentials generated or sent.');
