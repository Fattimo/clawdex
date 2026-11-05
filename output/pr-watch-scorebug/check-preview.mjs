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
  await call('Page.navigate',{url:'file://' + directory + 'preview.html'});
  let context;
  for(let attempt=0;attempt<40&&!context;attempt++) {
    await new Promise(r=>setTimeout(r,100));
    for(const c of contexts.values()) {
      try {const result=await call('Runtime.evaluate',{contextId:c.id,expression:'!!document.getElementById("dog-scorebug-prototype")',returnByValue:true});if(result.result.value){context=c.id;break;}}catch{}
    }
  }
  assert(context,'Mockup iframe found');
  const evaluate=async expression=>{
    const result=await call('Runtime.evaluate',{contextId:context,expression,returnByValue:true,awaitPromise:true});
    if(result.exceptionDetails)throw new Error(JSON.stringify(result.exceptionDetails));return result.result.value;
  };
  const click=selector=>evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
  const screenshot=async name=>{const shot=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:true});await writeFile(directory+name,Buffer.from(shot.data,'base64'));};
  await new Promise(r=>setTimeout(r,150));
  assert.equal(await evaluate(`document.querySelector('.ds-dog').naturalWidth`),192);
  assert.equal(await evaluate(`document.querySelectorAll('[data-session]').length`),4);
  assert.equal(await evaluate(`document.querySelectorAll('[data-pr]').length`),4);
  const geometry=await evaluate(`(()=>{const d=document.querySelector('.ds-dog').getBoundingClientRect();return [...document.querySelectorAll('.ds-switch')].every(b=>Math.abs(b.getBoundingClientRect().width-d.width)<1)})()`);
  assert(geometry,'Session switches have the same width as the dog');
  await screenshot('scorebug.png');
  const dogY=await evaluate(`document.querySelector('.ds-dog').getBoundingClientRect().y`);
  await click('[data-pr="billing"]');
  assert.equal(await evaluate(`document.querySelector('.ds-detail-title').textContent`),'Billing rollout');
  assert.equal(await evaluate(`document.querySelector('.ds-dog').getBoundingClientRect().y`),dogY);
  await screenshot('details.png');
  await click('.ds-close');
  assert.equal(await evaluate('document.activeElement.dataset.pr'),'billing');
  await click('[data-session="api"]');
  assert.equal(await evaluate(`document.querySelector('.ds-message').textContent`),'Running the search checks…');
  await click('[data-pr="auth"]');
  await evaluate(`document.querySelector('#dog-scorebug-prototype').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))`);
  assert.equal(await evaluate(`document.querySelector('.ds-detail').hidden`),true);
  for(const width of [736,375,320]) {
    await call('Emulation.setDeviceMetricsOverride',{width,height:900,deviceScaleFactor:1,mobile:false});
    await new Promise(r=>setTimeout(r,150));
    const dimensions=await evaluate('({width:innerWidth,scroll:document.documentElement.scrollWidth})');
    assert(dimensions.scroll<=dimensions.width,JSON.stringify({width,...dimensions}));
  }
  await screenshot('mobile.png');
  assert.deepEqual(errors,[]);
  console.log('PASS: equal session widths, four sessions, four PRs, bubble selection, stable dog position, chain details, close/Escape focus, responsive widths, no runtime errors.');
  await Promise.race([call('Browser.close'),new Promise(resolve=>setTimeout(resolve,300))]);
} finally {
  ws?.close();chrome.kill();
  await new Promise(resolve=>setTimeout(resolve,200));
  await rm(profile,{recursive:true,force:true});
}
