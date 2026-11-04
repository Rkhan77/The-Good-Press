/* Optional first-party attribution. No tracking/storage before explicit consent. */
(function(root){
 'use strict';
 const KEYS=['utm_source','utm_medium','utm_campaign','utm_content','utm_term'];
 const TTL=30*86400000;
 function sanitize(search){const q=new URLSearchParams(search),result={};for(const k of KEYS){const v=q.get(k);if(v&&/^[a-zA-Z0-9_-]{1,80}$/.test(v))result[k]=v;}return result;}
 function create({storage,location,crypto,send,now=()=>Date.now()}){
 let pending=sanitize(location.search),lastSession=null;
 const get=k=>{try{return storage.getItem(k);}catch{return null;}};
 const put=(k,v)=>{try{storage.setItem(k,v);}catch{}};
 const remove=k=>{try{storage.removeItem(k);}catch{}};
 const allowed=()=>get('gp-analytics-consent')==='yes';
 function attribution(){if(!allowed())return null;try{const saved=JSON.parse(get('gp-attribution')||'null');if(saved&&now()-saved.at<TTL)return saved.utm;remove('gp-attribution');}catch{}return null;}
 function capture(){if(allowed()&&pending.utm_campaign)put('gp-attribution',JSON.stringify({utm:pending,at:now()}));}
 async function event(name,session){if(!allowed())return;const utm=attribution();if(!utm)return;let id=get('gp-visitor');if(!id){id=crypto.randomUUID();put('gp-visitor',id);}try{await send({event_id:crypto.randomUUID(),visitor_id:id,event:name,utm,consent:true},session);}catch{/* Analytics must never interrupt reading or sign-in. */}}
 function consent(yes){put('gp-analytics-consent',yes?'yes':'no');if(!yes){remove('gp-attribution');remove('gp-visitor');return;}capture();void event('landing');if(lastSession)void signedIn(lastSession);}
 async function signedIn(session){lastSession=session;if(!session)return;const fresh=now()-Date.parse(session.user.created_at)<86400000;await event(fresh?'signup':'returning',session);}
 capture();
 return {consent,allowed,event,signedIn,attribution,start:()=>event('landing')};
 }
 root.GoodPressAttribution={sanitize,create};
 if(typeof module!=='undefined')module.exports=root.GoodPressAttribution;
})(typeof window==='undefined'?globalThis:window);
