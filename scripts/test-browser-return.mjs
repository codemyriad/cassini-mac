// SPDX-License-Identifier: GPL-3.0-or-later
// Actual app + Chromium extension/native messaging on disposable hosted Macs only.
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import {mkdir, mkdtemp, readFile, writeFile, stat, rm} from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';

assert.equal(process.env.GITHUB_ACTIONS, 'true');
assert.equal(process.env.RUNNER_ENVIRONMENT, 'github-hosted', 'Never run on a user desktop');
const {chromium} = await import(process.env.PLAYWRIGHT_MODULE || '../BrowserExtension/tests/node_modules/playwright/index.mjs');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = path.resolve(process.argv[2]), output = path.resolve(process.argv[3]);
const base = await mkdtemp(path.join(root, 'build/browser-background-return-'));
const app = path.join(base, 'Installed Cassini.app');
const profile = path.join(os.userInfo().homedir, 'Library/Application Support/Google/Chrome for Testing');
const controlRoot = path.join(os.userInfo().homedir, 'Library/Containers/io.codemyriad.cassini/Data/tmp', path.basename(base), 'control');
const pageBody = `<!doctype html><title>D33 real call</title><body>Generated WebRTC call<script>
(async () => {
 const context = new AudioContext(); const oscillator = context.createOscillator();
 oscillator.frequency.value = location.pathname === '/return' ? 660 : 880;
 const output = context.createMediaStreamDestination(); oscillator.connect(output); oscillator.start(); await context.resume();
 const sender = new RTCPeerConnection(), receiver = new RTCPeerConnection();
 window.generatedCall = {context,oscillator,output,sender,receiver};
 sender.addTrack(output.stream.getAudioTracks()[0]);
 receiver.ontrack = async event => { const audio = document.createElement('audio'); audio.muted = true; audio.srcObject = new MediaStream([event.track]); document.body.append(audio); await audio.play(); };
 const gathered = async pc => { if (pc.iceGatheringState !== 'complete') await new Promise(resolve => pc.addEventListener('icegatheringstatechange', () => { if (pc.iceGatheringState === 'complete') resolve(); })); };
 await sender.setLocalDescription(await sender.createOffer()); await gathered(sender);
 await receiver.setRemoteDescription(sender.localDescription); await receiver.setLocalDescription(await receiver.createAnswer()); await gathered(receiver);
 await sender.setRemoteDescription(receiver.localDescription);
 window.generatedCall = {context,oscillator,output,sender,receiver};
})().catch(error => { window.callError = String(error); });
</script>`;
let releaseNavigation, pendingResponse;
const server = http.createServer((request,response) => {
 const send = () => { response.writeHead(200, {'Content-Type':'text/html'}); response.end(pageBody); };
 if (request.url === '/return') { pendingResponse = response; releaseNavigation = send; }
 else send();
});
await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
const url = `http://127.0.0.1:${server.address().port}`;
let ownsProfile = false, context, child, stderr = '', stdout = '', exited = false, exitCode;
const phases = new Map();
const wait = async (predicate, message, timeout=45000) => {
 const deadline = Date.now()+timeout;
 while (!predicate() && Date.now()<deadline) {
  if (exited && exitCode !== 0) throw new Error(`App failed (${exitCode}): ${stderr}\n${stdout}`);
  await new Promise(resolve => setTimeout(resolve,25));
 }
 assert.ok(predicate(), `${message}\n${stderr}\n${stdout}`);
};
const connected = async page => {
 try {
  await page.waitForFunction(() => window.generatedCall?.receiver.connectionState === 'connected');
 } catch(error) {
  const diagnostic=await page.evaluate(() => ({error:window.callError,
   context:window.generatedCall?.context.state,
   peers:['sender','receiver'].map(key => {
    const peer=window.generatedCall?.[key];
    return {key,connection:peer?.connectionState,ice:peer?.iceConnectionState,gathering:peer?.iceGatheringState,
     localCandidates:(peer?.localDescription?.sdp.match(/^a=candidate:/gm)||[]).length,
     remoteCandidates:(peer?.remoteDescription?.sdp.match(/^a=candidate:/gm)||[]).length};
   })}))).catch(() => ({pageUnavailable:true}));
  stderr+='Generated call diagnostics: '+JSON.stringify(diagnostic)+'\n';
  console.error('Generated call diagnostics',JSON.stringify(diagnostic));
  throw error;
 }
};
try {
 await assert.rejects(stat(profile), {code:'ENOENT'}, 'Requires a fresh disposable profile');
 await mkdir(profile,{recursive:true}); ownsProfile=true;
 await mkdir(controlRoot,{recursive:true,mode:0o700});
 await mkdir(path.dirname(output),{recursive:true});
 execFileSync('ditto',[source,app]);
 execFileSync('codesign',['--verify','--deep','--strict',app]);
 const env = {...process.env,CASSINI_CONTROL_PIPE_ROOT:controlRoot,CASSINI_HOSTED_SCREENSHOTS:'1'};
 const chromiumApp = chromium.executablePath().split('/Contents/')[0];
 execFileSync('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',['-f',chromiumApp]);
 context = await chromium.launchPersistentContext(profile,{
  channel:'chromium',headless:true,env,
  args:[`--disable-extensions-except=${root}/BrowserExtension`,`--load-extension=${root}/BrowserExtension`,'--autoplay-policy=no-user-gesture-required','--allow-loopback-in-peer-connection','--disable-features=WebRtcHideLocalIpsWithMdns']
 });
 const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
 assert.equal(new URL(worker.url()).host,'pcafdaahfhjiolfpfnlhmljfgoabbaij');
 const page = await context.newPage();
 page.on('pageerror',error => {stderr+='Page error: '+error.message+'\n';});
 await page.goto(url);
 await connected(page);
 child = spawn(path.join(app,'Contents/MacOS/Cassini'),['--browser-return-self-test','--fixture-library-recording',
  '-CassiniCaptureID',crypto.randomUUID(),'-CassiniDiskFree',String(20*2**30),'-CassiniDiskTotal',String(100*2**30),'-ApplePersistenceIgnoreState','YES'],{env,detached:true});
 child.stdout.on('data',data => {
  stdout+=data;
  for (const line of stdout.split('\n').slice(0,-1)) {
   try { const report=JSON.parse(line); if(report.phase) phases.set(report.phase,report); } catch {}
  }
 });
 child.stderr.on('data',data => {stderr+=data;});
 child.on('error',error => {stderr+=String(error); exited=true; exitCode=-1;});
 child.on('exit',code => {exited=true; exitCode=code;});
 await wait(() => phases.has('recording'),'No real app-owned browser recording');
 // Leave the real navigation pending until the app proves actual system PCM.
 const navigation = page.goto(url+'/return',{timeout:60000}).then(() => null,error => error);
 await wait(() => Boolean(releaseNavigation),'Navigation did not reach the server');
 await wait(() => phases.has('fallback'),'App did not start fallback during navigation');
 releaseNavigation(); releaseNavigation=null;
 assert.equal(await navigation,null);
 await connected(page);
 await wait(() => phases.has('restored'),'App did not restore real browser PCM');
 assert.equal(phases.get('recording').id,phases.get('fallback').id);
 assert.equal(phases.get('recording').id,phases.get('restored').id);
 await page.close();
 await wait(() => phases.has('complete'),'Closing the real tab did not persist its terminal event');
 await wait(() => exited,'App did not finish cleanly');
 assert.equal(exitCode,0,stderr);
 const report=phases.get('complete');
 for(const key of ['sameFolder','originalTransport','realPageLifecycle','systemFallback','freshBrowserSpan','microphoneUninterrupted','nativeInputsGenerated']) assert.equal(report[key],true,key);
 assert.equal(report.endReason,'tabClosed'); assert.equal(report.audioDevicesOpened,false);
 report.realChromium=true; report.realExtension=true; report.nativeArchitecture=os.arch();
 await writeFile(output,JSON.stringify(report,null,2)+'\n');
 console.log('PASS real Chromium navigation → app-owned system fallback → original transport/new browser span → tabClosed, same folder and uninterrupted mic');
} finally {
 await mkdir(path.dirname(output),{recursive:true});
 await writeFile(output+'.stderr.txt',stderr); await writeFile(output+'.stdout.txt',stdout);
 if(child && !exited) {try {process.kill(-child.pid,'SIGKILL');} catch {}}
 pendingResponse?.destroy();
 await context?.close(); server.closeAllConnections(); server.close();
 if(ownsProfile) await rm(profile,{recursive:true,force:true});
 await rm(path.dirname(controlRoot),{recursive:true,force:true});
 await rm(base,{recursive:true,force:true});
}
