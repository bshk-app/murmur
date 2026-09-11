import fs from 'node:fs';
import os from 'node:os';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
const buildID='a0fcd0e0-78e8-40b2-9cf8-3ba996fbcd5d',groupID='d79330c5-ed46-4449-aafe-5963bee69041',appID='6809815142',kid='38V7FDZ48J';
const issuer=execFileSync('op',['read','op://Private/o5ocl3hneq2mobu6exk4vtbqhu/Issuer ID'],{encoding:'utf8',stdio:['ignore','pipe','inherit']}).trim();
const key=fs.readFileSync(os.homedir()+'/.appstoreconnect/private_keys/AuthKey_'+kid+'.p8');
async function api(route,method='GET',body){const enc=x=>Buffer.from(JSON.stringify(x)).toString('base64url'),now=Math.floor(Date.now()/1000),p=enc({alg:'ES256',kid,typ:'JWT'})+'.'+enc({iss:issuer,aud:'appstoreconnect-v1',iat:now,exp:now+120}),sig=crypto.sign('sha256',Buffer.from(p),{key,dsaEncoding:'ieee-p1363'}).toString('base64url');const response=await fetch('https://api.appstoreconnect.apple.com'+route,{method,headers:{Authorization:'Bearer '+p+'.'+sig,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});const raw=await response.text();const data=raw?JSON.parse(raw):{};if(!response.ok)throw Error(JSON.stringify({status:response.status,errors:data.errors?.map(e=>({code:e.code,detail:e.detail}))}));return data;}
const buildRoute='/v1/builds/'+buildID+'?include=app,preReleaseVersion,buildBetaDetail,betaAppReviewSubmission,betaGroups';
let b=await api(buildRoute);const group=await api('/v1/betaGroups/'+groupID);
if(b.data.attributes.version!=='19'||b.data.relationships.app.data.id!==appID||b.data.attributes.processingState!=='VALID')throw Error('Unexpected build or processing state');
if(group.data.attributes.name!=='Murmator Beta'||group.data.attributes.isInternalGroup||!group.data.attributes.publicLinkEnabled)throw Error('Unexpected public group');
const loc=await api('/v1/builds/'+buildID+'/betaBuildLocalizations');
const en=loc.data.find(x=>x.attributes.locale==='en-US');const description='Test Safari page translation through Share → Murmator. The separate language/progress window is retained. This build fixes page translation failing on invisible formatting characters (including the HUS Anna palautetta page). Check Finnish → Russian translation, cancellation, and restoring the original page.';
if(!en)await api('/v1/betaBuildLocalizations','POST',{data:{type:'betaBuildLocalizations',attributes:{locale:'en-US',description},relationships:{build:{data:{type:'builds',id:buildID}}}}});
else if(!en.attributes.description?.trim())await api('/v1/betaBuildLocalizations/'+en.id,'PATCH',{data:{type:'betaBuildLocalizations',id:en.id,attributes:{description}}});
const membership=await api('/v1/betaGroups/'+groupID+'/relationships/builds');
if(!membership.data.some(x=>x.id===buildID)){await api('/v1/builds/'+buildID+'/relationships/betaGroups','POST',{data:[{type:'betaGroups',id:groupID}]});console.log('Build 19 added to Murmator Beta.');}
b=await api(buildRoute);const detail=b.included?.find(x=>x.type==='buildBetaDetails');
if(detail?.attributes.externalBuildState==='READY_FOR_BETA_SUBMISSION'){const submitted=await api('/v1/betaAppReviewSubmissions','POST',{data:{type:'betaAppReviewSubmissions',relationships:{build:{data:{type:'builds',id:buildID}}}}});console.log(JSON.stringify({submitted:true,review:submitted.data?.attributes}));}
b=await api(buildRoute);const members=await api('/v1/betaGroups/'+groupID+'/relationships/builds');const beta=b.included?.find(x=>x.type==='buildBetaDetails');const review=b.included?.find(x=>x.type==='betaAppReviewSubmissions');const result={checkedAt:new Date().toISOString(),build:'19',buildID,group:'Murmator Beta',groupContainsBuild:members.data.some(x=>x.id===buildID),publicLink:group.data.attributes.publicLink,processing:b.data.attributes.processingState,externalBuildState:beta?.attributes.externalBuildState,review:review?.attributes};fs.writeFileSync('Applications/iOS/Release/1.0.0-19/external-review.json',JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result,null,2));
