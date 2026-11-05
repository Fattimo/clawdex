import { spawn } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';

const directory = new URL('.', import.meta.url).pathname;
const profile = await mkdtemp(join(tmpdir(), 'branchwood-preview-'));
const chrome = spawn('/Users/fattimo/Library/Caches/ms-playwright/chromium_headless_shell-1243/chrome-headless-shell-mac-arm64/chrome-headless-shell', [
  '--headless', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
  '--disable-background-networking', '--remote-debugging-address=127.0.0.1',
  '--remote-debugging-port=0', '--user-data-dir=' + profile, 'about:blank'
], {stdio:['ignore','ignore','pipe']});
let ws;
try {
  let browserURL = '';
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Browser launch timeout')), 10000);
    chrome.on('error', reject);
    chrome.stderr.on('data', chunk => {
      const match = chunk.toString().match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) { browserURL = match[1]; clearTimeout(timeout); resolve(); }
    });
  });
  const origin = new URL(browserURL).origin.replace('ws:', 'http:');
  const targets = await (await fetch(origin + '/json/list')).json();
  ws = new WebSocket(targets.find(t => t.type === 'page').webSocketDebuggerUrl);
  await new Promise((resolve,reject) => {ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',reject,{once:true});});
  const pending = new Map(); const contexts = new Map(); const errors = []; let sequence=0;
  ws.addEventListener('message',event => {
    const message=JSON.parse(event.data);
    if(message.id) {const p=pending.get(message.id);pending.delete(message.id);if(message.error)p.reject(message.error);else p.resolve(message.result);}
    if(message.method==='Runtime.executionContextCreated')contexts.set(message.params.context.id,message.params.context);
    if(message.method==='Runtime.executionContextDestroyed')contexts.delete(message.params.executionContextId);
    if(message.method==='Runtime.exceptionThrown')errors.push(message.params.exceptionDetails.text);
  });
  const call=(method,params={})=>new Promise((resolve,reject)=>{const id=++sequence;pending.set(id,{resolve,reject});ws.send(JSON.stringify({id,method,params}));});
  await call('Runtime.enable');await call('Page.enable');
  await call('Emulation.setDeviceMetricsOverride',{width:1024,height:1040,deviceScaleFactor:1,mobile:false});
  await call('Page.navigate',{url:'https://github.com/cli/cli/pull/14927#partial-pull-merging'});
  let result;
  for(let attempt=0;attempt<60;attempt++) {
    await new Promise(resolve=>setTimeout(resolve,300));
    const reply=await call('Runtime.evaluate',{expression:`(()=>{const merge=document.getElementById('partial-pull-merging');return {title:document.title,found:!!merge,scrollY,top:merge?.getBoundingClientRect().top,ids:[...document.querySelectorAll('[id]')].map(e=>e.id).filter(id=>/merg/i.test(id))}})()`,returnByValue:true});
    result=reply.result.value;
    if(result?.found) break;
  }
  console.log(JSON.stringify(result));
  await Promise.race([call('Browser.close'),new Promise(resolve=>setTimeout(resolve,300))]);
} finally {
  ws?.close();chrome.kill();
  await new Promise(resolve=>setTimeout(resolve,200));
  await rm(profile,{recursive:true,force:true});
}
