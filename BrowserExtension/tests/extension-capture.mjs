import { workerDeathDuringRecording } from '../../browser-protocol/scenarios/worker-recovery.mjs';
import { tonePower } from '../../browser-protocol/scenarios/tones.mjs';
import { saveFailure } from './artifacts.mjs';
// Optional integration test. See README.md for the temporary Playwright setup.
import { createServer } from 'node:http';
import { generateKeyPairSync } from 'node:crypto';
import { mkdir, writeFile, readFile, rm, mkdtemp, cp } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const server = createServer((_request, response) => {
  response.end('<!doctype html><title>Cassini synthetic extension test</title><button>Allow audio</button>');
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const sandbox = await mkdtemp(path.join(os.tmpdir(), 'cassini-extension-'));
const profile = path.join(sandbox,'profile'), extension = path.join(sandbox,'extension'), library = path.join(sandbox,'Library');
await mkdir(library);
await cp(path.join(root,'BrowserExtension'),extension,{recursive:true,filter:source => !source.startsWith(path.join(root,'BrowserExtension/tests'))});
const manifestPath = path.join(extension,'manifest.json');
const extensionManifest = JSON.parse(await readFile(manifestPath,'utf8'));
extensionManifest.key = generateKeyPairSync('rsa',{modulusLength:2048}).publicKey.export({type:'spki',format:'der'}).toString('base64');
await writeFile(manifestPath,JSON.stringify(extensionManifest));
const hostPath = process.env.CASSINI_NATIVE_HOST || path.join(root,'.build/debug/cassini-browser-host');
assert.match(hostPath, /\/(?:debug|Debug)\//, 'The private-Library fixture requires a Debug native host');
let context, savedPath;
// A serviceworker target can exist before its message listener is installed.
// Observe that registration before issuing the first RPC; never retry an RPC.
async function ready(worker) {
  await worker.evaluate(()=>new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>{clearInterval(check);reject(Error('Worker message listener did not register'));},15000);
    const check=setInterval(()=>{
      if(chrome.runtime.onMessage.hasListeners()){clearInterval(check);clearTimeout(timer);resolve();}
    },10);
    if(chrome.runtime.onMessage.hasListeners()){clearInterval(check);clearTimeout(timer);resolve();}
  }));
}
try {
  context = await chromium.launchPersistentContext(profile, {
    channel: 'chromium', headless: true,
    env:{...process.env,CASSINI_LIBRARY_DIR:library},
    args: [`--disable-extensions-except=${extension}`,
      `--load-extension=${extension}`, '--autoplay-policy=no-user-gesture-required']
  });
  let worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
  console.log('Chromium', context.browser().version());
  const extensionId = new URL(worker.url()).host;
  await ready(worker);
  // Modern Chromium looks for native hosts under this temporary user-data directory.
  // This does not install a host or an extension into the user's everyday browser profile.
  const hostDirectory = path.join(profile, 'NativeMessagingHosts');
  await mkdir(hostDirectory, { recursive: true });
  await writeFile(path.join(hostDirectory, 'io.codemyriad.cassini.json'), JSON.stringify({
    name: 'io.codemyriad.cassini', description: 'Cassini integration test',
    path: hostPath,
    type: 'stdio', allowed_origins: [`chrome-extension://${extensionId}/`]
  }));

  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.click('button');
  await page.evaluate(async () => {
    const audio = new AudioContext();
    const oscillator = audio.createOscillator();
    const output = audio.createMediaStreamDestination();
    oscillator.connect(output); oscillator.start(); await audio.resume();
    const element = document.createElement('audio');
    element.srcObject = output.stream; element.muted = true;
    document.body.append(element); await element.play();
    window.synthetic = { audio, oscillator, output, element };
  });
  // Explicit termination is the worker lifecycle event; a fixed idle delay
  // cannot establish it while debugger attachment keeps a worker alive.
  const lifecycle=await context.newCDPSession(page);
  let versions=[], signals=[];
  lifecycle.on('ServiceWorker.workerVersionUpdated',event=>{
    versions=event.versions;
    for(const signal of [...signals])signal();
  });
  const versionState=predicate=>new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>{signals=signals.filter(x=>x!==check);reject(Error('Worker lifecycle event did not arrive'));},15000);
    function check(){const value=versions.find(predicate);if(value){clearTimeout(timer);signals=signals.filter(x=>x!==check);resolve(value);}}
    signals.push(check);check();
  });
  await lifecycle.send('ServiceWorker.enable');
  const running=await versionState(value=>value.scriptURL===`chrome-extension://${extensionId}/background.js` && value.runningStatus==='running');
  const stopped=versionState(value=>value.versionId===running.versionId && value.runningStatus==='stopped');
  await lifecycle.send('ServiceWorker.stopWorker',{versionId:running.versionId});
  await stopped;
  await lifecycle.detach();
  const wake = await context.newPage();
  await wake.goto(`chrome-extension://${extensionId}/popup.html`);
  worker=context.serviceWorkers().find(item=>item.url().includes(extensionId)) || await context.waitForEvent('serviceworker');
  await ready(worker);
  await wake.evaluate(() => chrome.runtime.sendMessage({ target: 'background', type: 'status' }));
  await wake.close();
  // Simulate action invocation's activeTab metadata grant in the temporary test profile.
  // The actual MAIN/isolated scripts, service worker and Native Messaging transport run normally.
  const meetingTab = await worker.evaluate(url => {
    const query = chrome.tabs.query.bind(chrome.tabs);
    return query({ active: true, currentWindow: true }).then(tabs => {
      const tab = { ...tabs[0], url, title: 'Synthetic extension test' };
      chrome.tabs.query = async () => [tab];
      return tab;
    });
  }, page.url());

  const popup = await context.newPage();
  await popup.goto(`chrome-extension://${extensionId}/popup.html`);
  const rpc = (type, extra={}) => popup.evaluate(message => chrome.runtime.sendMessage(message),{target:'background',type,...extra});
  // Product popup controls are absent. Use the same trusted fixture transport
  // as the shared worker-recovery scenario; UI policy is tested separately.
  await popup.exposeFunction('fixtureSamples',async (state, tracks, seconds) => {
    if (!state.path || !state.recording || state.tracks !== tracks) return false;
    assert.ok(path.resolve(state.path).startsWith(path.resolve(library)+path.sep),'Capture escaped its private Library');
    const metadata=JSON.parse(await readFile(path.join(state.path,'session.json')));
    if(metadata.tracks.length !== tracks)return false;
    for(const track of metadata.tracks){
      const wav=await readFile(path.join(state.path,track.file));
      if((wav.length-44)/(track.channels*2) < track.sampleRate*seconds)return false;
    }
    return true;
  });
  async function waitStatus(options) {
    return popup.evaluate(options=>new Promise((resolve,reject)=>{
      let done=false;
      const timer=setTimeout(()=>{done=true;reject(Error('Timed out waiting for saved audio/status'));},20000);
      async function check(){
        if(done)return;
        try {
          const state=await chrome.runtime.sendMessage({target:'background',type:'status'});
          const ready=options.stopped ? !state.recording : await window.fixtureSamples(state,options.tracks,options.seconds);
          if(ready){done=true;clearTimeout(timer);resolve(state);return;}
          requestAnimationFrame(check);
        } catch(error){done=true;clearTimeout(timer);reject(error);}
      }
      check();
    }),options);
  }
  const recorded=(tracks,seconds)=>waitStatus({tracks,seconds});
  const started=await rpc('start',{mode:'tracks'});
  assert.ok(!started.error,JSON.stringify(started)); savedPath=started.path;
  const during=await recorded(1,2);
  savedPath=during.path;
  assert.equal(during.recording,true,JSON.stringify(during));
  const after=await rpc('stop');
  assert.ok(!after.error,JSON.stringify(after));
  assert.equal(after.recording, false);
  assert.equal(after.message, 'Saved on this computer.');
  assert.equal(during.tracks, 1);
  const manifest = JSON.parse(await readFile(path.join(savedPath, 'session.json')));
  assert.equal(manifest.state, 'completed');
  assert.equal(manifest.tracks[0].kind, 'media');
  const wav = await readFile(path.join(savedPath, manifest.tracks[0].file));
  assert.ok(wav.subarray(44).some(byte => byte !== 0), 'recorded a generated tone');
  assert.deepEqual(errors, []);
  savedPath = null; // The private sandbox is removed after all scenarios.
  const crashed = await workerDeathDuringRecording({ context, meetingPage: page, popup, extensionId, library });
  worker = context.serviceWorkers().find(item => item.url().includes(extensionId)) || await context.waitForEvent('serviceworker');
  await worker.evaluate(tab => { chrome.tabs.query = async () => [tab]; }, meetingTab);
  await page.evaluate(() => {
    const frame = document.createElement('iframe');
    frame.srcdoc = `<body><script>
      const audio = new AudioContext(), oscillator = audio.createOscillator(), output = audio.createMediaStreamDestination();
      oscillator.frequency.value = 880; oscillator.connect(output); oscillator.start(); audio.resume();
      const element = document.createElement('audio'); element.srcObject = output.stream; element.muted = true;
      document.body.append(element); element.play();
    <\/script>`;
    document.body.append(frame);
  });
  const next=await rpc('start',{mode:'tracks'});
  assert.ok(!next.error,JSON.stringify(next)); savedPath=next.path;
  const beforeNavigation=await recorded(2,1.5);
  savedPath = beforeNavigation.path;
  assert.equal(beforeNavigation.recording, true);
  assert.equal(beforeNavigation.tracks, 2, "parent and about:srcdoc frame captured");
  await page.goto(`http://127.0.0.1:${server.address().port}/navigated`);
  const finalStatus=await waitStatus({stopped:true});
  assert.equal(finalStatus.recording, false, JSON.stringify(finalStatus));

  const interrupted = JSON.parse(await readFile(path.join(savedPath, 'session.json')));
  assert.equal(interrupted.state, 'interrupted');
  assert.match(interrupted.problem, /closed|navigated|disconnected/);
  assert.ok(interrupted.tracks[0].frames > 0);
  const partial = await readFile(path.join(savedPath, interrupted.tracks[0].file));
  assert.equal(partial.readUInt32LE(40), partial.length - 44);
  const frequencies = [];
  for (const track of interrupted.tracks) {
    const audio = await readFile(path.join(savedPath, track.file));
    const power440 = tonePower(audio, track.sampleRate, 440);
    const power880 = tonePower(audio, track.sampleRate, 880);
    assert.ok(Math.max(power440, power880) > 0.001, 'frame contains its generated tone');
    assert.ok(Math.min(power440, power880) < Math.max(power440, power880) * 0.01, 'frame separation has less than one percent bleed');
    frequencies.push(power440 > power880 ? 440 : 880);
  }
  assert.deepEqual(frequencies.sort(), [440, 880]);
  console.log('PASS: loaded extension → Chrome Native Messaging → WAV; restarted worker, normal stop, iframe separation and navigation preserve audio');
} catch (error) {
  await saveFailure('extension-capture', error, savedPath);
  throw error;
} finally {
  await context?.close();
  server.close();
  await rm(sandbox, { recursive: true, force: true });
}
