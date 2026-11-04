const CACHE_NAME='the-good-press-v49';
const APP_SHELL=['./','./index.html','./manifest.webmanifest','./supabase-config.js','./marketing-attribution.js','./icons/icon.svg','./icons/icon-192.png','./icons/icon-512.png'];
self.addEventListener('install',event=>{event.waitUntil(caches.open(CACHE_NAME).then(cache=>cache.addAll(APP_SHELL)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',event=>{event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key!==CACHE_NAME).map(key=>caches.delete(key)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',event=>{
 const url=new URL(event.request.url);
 if(event.request.method!=='GET'||url.origin!==self.location.origin)return;
 if(url.pathname.startsWith('/admin/')||url.pathname.startsWith('/api/')||url.pathname.startsWith('/generated/'))return;
 const appNavigation=event.request.mode==='navigate'&&(url.pathname.endsWith('/')||url.pathname.endsWith('/index.html'));
 if(appNavigation){
  // Cache only the clean app shell URL; OAuth codes and UTM parameters never become cache keys.
  event.respondWith(fetch(event.request).then(response=>{if(response.ok){const copy=response.clone();caches.open(CACHE_NAME).then(cache=>cache.put('./index.html',copy));}return response}).catch(()=>caches.match('./index.html')));
  return;
 }
 if(event.request.mode==='navigate')return; // Legal pages remain network served.
 event.respondWith(caches.match(event.request).then(cached=>cached||fetch(event.request).then(response=>{if(response.ok){const copy=response.clone();caches.open(CACHE_NAME).then(cache=>cache.put(event.request,copy));}return response})));
});
