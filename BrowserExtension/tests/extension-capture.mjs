import { tonePower } from '../../browser-protocol/scenarios/tones.mjs';
import { saveFailure } from './artifacts.mjs';
// Optional integration test. See README.md for the temporary Playwright setup.
import { createServer } from 'node:http';
import { mkdir, writeFile, readFile, rm, mkdtemp } from 'node:fs/promises';
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
const profile = await mkdtemp(path.join(os.tmpdir(), 'cassini-extension-'));
let context, savedPath;
try {
  context = await chromium.launchPersistentContext(profile, {
    channel: 'chromium', headless: true,
    args: [`--disable-extensions-except=${root}/BrowserExtension`,
      `--load-extension=${root}/BrowserExtension`, '--autoplay-policy=no-user-gesture-required']
  });
  let worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
  console.log('Chromium', context.browser().version());
  const extensionId = new URL(worker.url()).host;
  // Modern Chromium looks for native hosts under this temporary user-data directory.
  // This does not install a host or an extension into the user's everyday browser profile.
  const hostDirectory = path.join(profile, 'NativeMessagingHosts');
  await mkdir(hostDirectory, { recursive: true });
  await writeFile(path.join(hostDirectory, 'com.codemyriad.cassini.json'), JSON.stringify({
    name: 'com.codemyriad.cassini', description: 'Cassini integration test',
    path: process.env.CASSINI_NATIVE_HOST || path.join(root, '.build/debug/cassini-browser-host'),
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
  // Let the relay/worker become idle, then terminate the worker explicitly as well:
  // debugger attachment can otherwise suppress normal idle termination during a test.
  await page.waitForTimeout(35000);
  const devtools = await context.newCDPSession(page);
  let versions = [];
  devtools.on('ServiceWorker.workerVersionUpdated', event => { versions = event.versions; });
  await devtools.send('ServiceWorker.enable');
  await page.waitForTimeout(200);
  const version = versions.find(item => item.scriptURL === `chrome-extension://${extensionId}/background.js`);
  assert.ok(version, 'found the loaded service worker');
  await devtools.send('ServiceWorker.stopWorker', { versionId: version.versionId });
  await devtools.detach();
  const wake = await context.newPage();
  await wake.goto(`chrome-extension://${extensionId}/popup.html`);
  await wake.evaluate(() => chrome.runtime.sendMessage({ target: 'background', type: 'status' }));
  worker = context.serviceWorkers().find(item => item.url().includes(extensionId)) || await context.waitForEvent('serviceworker');
  await wake.close();
  // Simulate action invocation's activeTab metadata grant in the temporary test profile.
  // The actual MAIN/isolated scripts, service worker and Native Messaging transport run normally.
  await worker.evaluate(url => {
    const query = chrome.tabs.query.bind(chrome.tabs);
    return query({ active: true, currentWindow: true }).then(tabs => {
      const tab = { ...tabs[0], url, title: 'Synthetic extension test' };
      chrome.tabs.query = async () => [tab];
    });
  }, page.url());

  const popup = await context.newPage();
  await popup.goto(`chrome-extension://${extensionId}/popup.html`);
  await popup.click('#tracks');
  await page.waitForTimeout(2000);
  const during = await popup.evaluate(() => chrome.runtime.sendMessage({ target: 'background', type: 'status' }));
  savedPath = during.path;
  assert.equal(during.recording, true, during.message);
  await popup.click('#stop');
  await popup.waitForFunction(() => !document.querySelector('#tracks').hidden);
  const after = await popup.evaluate(() => chrome.runtime.sendMessage({ target: 'background', type: 'status' }));
  assert.equal(after.recording, false);
  assert.equal(after.message, 'Saved on this computer.');
  assert.equal(during.tracks, 1);
  const manifest = JSON.parse(await readFile(path.join(savedPath, 'session.json')));
  assert.equal(manifest.state, 'completed');
  assert.equal(manifest.tracks[0].kind, 'media');
  const wav = await readFile(path.join(savedPath, manifest.tracks[0].file));
  assert.ok(wav.subarray(44).some(byte => byte !== 0), 'recorded a generated tone');
  assert.deepEqual(errors, []);
  await rm(savedPath, { recursive: true, force: true }); savedPath = null;
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
  await popup.click('#tracks');
  await page.waitForTimeout(2000);
  const beforeNavigation = await popup.evaluate(() => chrome.runtime.sendMessage({ target: 'background', type: 'status' }));
  savedPath = beforeNavigation.path;
  assert.equal(beforeNavigation.recording, true);
  assert.equal(beforeNavigation.tracks, 2, "parent and about:srcdoc frame captured");
  await page.goto(`http://127.0.0.1:${server.address().port}/navigated`);
  let finalStatus;
  for (let attempt = 0; attempt < 200; attempt++) {
    finalStatus = await popup.evaluate(() => chrome.runtime.sendMessage({ target: 'background', type: 'status' }));
    if (!finalStatus.recording) break;
    await popup.waitForTimeout(100);
  }
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
  console.log('PASS: loaded extension → Chrome Native Messaging → WAV; idle/restarted worker, normal stop, iframe separation and navigation preserve audio');
} catch (error) {
  await saveFailure('extension-capture', error, savedPath);
  throw error;
} finally {
  await context?.close();
  server.close();
  if (savedPath) await rm(savedPath, { recursive: true, force: true });
  await rm(profile, { recursive: true, force: true });
}
