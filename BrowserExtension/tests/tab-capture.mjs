import { workerDeathDuringRecording } from '../../browser-protocol/scenarios/worker-recovery.mjs';
import { installZoomLikeAudio } from '../../browser-protocol/scenarios/product-topologies.mjs';
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
const profileRoot = process.env.CASSINI_TEST_PROFILE_ROOT || os.tmpdir();
await mkdir(profileRoot, { recursive: true });
const profile = await mkdtemp(path.join(profileRoot, 'cassini-tab-'));
const launch = extra => chromium.launchPersistentContext(profile, {
  channel: 'chromium', headless: true, ignoreDefaultArgs: ['--mute-audio'],
  args: [`--disable-extensions-except=${root}/BrowserExtension`,
    `--load-extension=${root}/BrowserExtension`, '--autoplay-policy=no-user-gesture-required', ...extra]
});
let context, savedPath;
try {
  context = await launch([]);
  const initialWorker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
  console.log('Chromium', context.browser().version());
  const extensionId = new URL(initialWorker.url()).host;
  await context.close();
  // Chromium's explicit testing allowlist supplies only the invocation grant. All actual
  // tabCapture/offscreen audio APIs run normally. The everyday browser is never modified.
  context = await launch([`--allowlisted-extension-id=${extensionId}`]);
  const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
  // Modern Chromium looks for native hosts under this temporary user-data directory.
  // This does not install a host or an extension into the user's everyday browser profile.
  const hostDirectory = path.join(profile, 'NativeMessagingHosts');
  await mkdir(hostDirectory, { recursive: true });
  await writeFile(path.join(hostDirectory, 'io.codemyriad.cassini.json'), JSON.stringify({
    name: 'io.codemyriad.cassini', description: 'Cassini integration test',
    path: process.env.CASSINI_NATIVE_HOST || path.join(root, '.build/debug/cassini-browser-host'),
    type: 'stdio', allowed_origins: [`chrome-extension://${extensionId}/`]
  }));

  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.click('button');
  await installZoomLikeAudio(page);
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
  await popup.click('#tab');
  let ready = false;
  for (let attempt = 0; attempt < 200; attempt++) {
    const state = await popup.evaluate(() => chrome.runtime.sendMessage({ target: 'background', type: 'status' }));
    savedPath = state.path;
    if (savedPath && state.recording && state.tracks === 1) {
      const metadata = JSON.parse(await readFile(path.join(savedPath, 'session.json')));
      const track = metadata.tracks[0];
      if (track) {
        const audio = await readFile(path.join(savedPath, track.file));
        if (audio.length >= 44 + track.sampleRate * track.channels * 2 * 1.25) { ready = true; break; }
      }
    }
    await page.waitForTimeout(100);
  }
  assert.ok(ready, 'tab capture produced at least 1.25 seconds of saved audio; this test requires a real output device');
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
  assert.equal(manifest.tracks[0].kind, 'tab');
  assert.equal(manifest.tracks[0].channels, 2);
  const wav = await readFile(path.join(savedPath, manifest.tracks[0].file));
  assert.ok(wav.length > 48000 * 4, 'at least a second of stereo audio');
  const rate = manifest.tracks[0].sampleRate;
  const count = Math.min(rate / 4, Math.floor((wav.length - 44) / 4 / 3));
  function power(frequency) {
    let real = 0, imaginary = 0;
    for (let i = 0; i < count; i++) {
      const value = wav.readInt16LE(44 + (i + count) * 4) / 32768;
      real += value * Math.cos(2 * Math.PI * frequency * i / rate);
      imaginary += value * Math.sin(2 * Math.PI * frequency * i / rate);
    }
    return (real ** 2 + imaginary ** 2) / count ** 2;
  }
  assert.ok(power(990) > 0.00001, 'captured the 990 Hz tone');
  assert.ok(power(990) > power(660) * 100, 'spectral identity preserved');
  assert.equal(await worker.evaluate(async () => (await chrome.runtime.getContexts({ contextTypes: ["OFFSCREEN_DOCUMENT"] })).length > 0), false);
  assert.deepEqual(errors, []);
  await rm(savedPath, { recursive: true, force: true }); savedPath = null;
  const crashed = await workerDeathDuringRecording({ context, meetingPage: page, popup, extensionId, mode: 'tab' });
  await rm(crashed.path, { recursive: true, force: true });
  console.log('PASS: tabCapture → offscreen AudioWorklet → Chrome Native Messaging → stereo WAV; 990 Hz verified; worker death retains audio and closes offscreen capture');
} catch (error) {
  await saveFailure('tab-capture', error, savedPath);
  throw error;
} finally {
  await context?.close();
  server.close();
  if (savedPath) await rm(savedPath, { recursive: true, force: true });
  await rm(profile, { recursive: true, force: true });
}
