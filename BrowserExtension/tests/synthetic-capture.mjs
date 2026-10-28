// SPDX-License-Identifier: GPL-3.0-or-later
import { answerWithTone, tonePower } from '../../browser-protocol/scenarios/tones.mjs';
import { saveFailure } from './artifacts.mjs';
import { toneWindow } from './tone-window.cjs';
// Optional integration test: npm install playwright in a temporary directory, then set
// PLAYWRIGHT_MODULE to its index.mjs. Uses only generated tones, never the microphone.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const host = spawn(process.env.CASSINI_NATIVE_HOST || path.join(root, '.build/debug/cassini-browser-host'), [], { stdio: ['pipe', 'pipe', 'inherit'] });
let incoming = Buffer.alloc(0), pending = [], savedPath;
host.stdout.on('data', data => {
  incoming = Buffer.concat([incoming, data]);
  while (incoming.length >= 4 && incoming.length >= 4 + incoming.readUInt32LE()) {
    const size = incoming.readUInt32LE();
    const message = JSON.parse(incoming.subarray(4, 4 + size));
    incoming = incoming.subarray(4 + size);
    const waiter = pending.shift();
    if (message.type === 'error') waiter?.reject(new Error(message.message));
    else waiter?.resolve(message);
  }
});
host.on('exit', code => { for (const request of pending.splice(0)) request.reject(new Error(`Native host exited: ${code}`)); });
function send(packet) {
  return new Promise((resolve, reject) => {
    pending.push({ resolve, reject });
    const data = Buffer.from(JSON.stringify(packet));
    const length = Buffer.alloc(4); length.writeUInt32LE(data.length);
    host.stdin.write(Buffer.concat([length, data]));
  });
}
const server = createServer(async (request, response) => {
  if (request.url === '/') { response.end('<!doctype html><title>Synthetic Cassini test</title>'); return; }
  const name = request.url.slice(1);
  if (!['capture.js', 'pcm-worklet.js'].includes(name)) { response.writeHead(404).end(); return; }
  response.setHeader('Content-Type', 'text/javascript');
  response.end(await readFile(path.join(root, 'BrowserExtension', name)));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
let browser;
const problems = [];
const packets = [];
try {
  const started = await send({ type: 'start', title: 'Cassini synthetic audio integration test' });
  savedPath = started.path;
  browser = await chromium.launch({ headless: true, args: ['--autoplay-policy=no-user-gesture-required', '--allow-loopback-in-peer-connection', '--disable-features=WebRtcHideLocalIpsWithMdns'] });
  console.log('Chromium', browser.version());
  const page = await browser.newPage();
  await page.addInitScript({ path: path.join(root, 'BrowserExtension/page-hook.js') });
  await page.exposeFunction('writeAudio', async packet => { packets.push(packet); await send(packet); });
  await page.exposeFunction('reportProblem', message => problems.push(message));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const offer = await page.evaluate(async () => {
    const context = new AudioContext();
    const oscillator = context.createOscillator();
    oscillator.frequency.value = 440;
    const output = context.createMediaStreamDestination();
    oscillator.connect(output); oscillator.start(); await context.resume();
    const a = new RTCPeerConnection();
    a.addTrack(output.stream.getAudioTracks()[0]);
    await a.setLocalDescription(await a.createOffer());
    if (a.iceGatheringState !== 'complete') await new Promise(resolve => a.addEventListener('icegatheringstatechange', () => {
      if (a.iceGatheringState === 'complete') resolve();
    }));
    const preview = document.createElement("audio");
    preview.srcObject = output.stream; preview.muted = true; document.body.append(preview); await preview.play();
    window.testAudio = { context, oscillator, output, a };
    window.captureStopped = false;
    window.addEventListener('message', async event => {
      if (event.data?.channel !== 'cassini-page') return;
      const message = event.data;
      if (message.type === 'packet') {
        let error;
        try { await window.writeAudio(message.packet); } catch (e) { error = e.message; }
        window.postMessage({ channel: 'cassini-control', type: 'ack', token: 'test', request: message.request, error }, '*');
      } else if (message.type === 'error') window.reportProblem(message.message);
      else if (message.type === 'stopped') window.captureStopped = true;
    });
    window.recordingOrigin = Date.now();
    window.postMessage({ channel: 'cassini-control', type: 'start', token: 'test', origin: window.recordingOrigin,
      moduleURL: location.origin + '/capture.js', workletURL: location.origin + '/pcm-worklet.js' }, '*');
    return a.localDescription.toJSON();
  });
  const remote = await browser.newPage();
  await remote.goto(page.url());
  const answer = await answerWithTone(remote, offer, 880);
  await page.evaluate(answer => testAudio.a.setRemoteDescription(answer), answer);
  // Several seconds exercise continuous messages, real WebRTC and render-clock timestamps.
  await page.waitForFunction(() => testAudio.a.connectionState === 'connected', null, { timeout: 10000 });
  async function recordedSource(kind, index, seconds) {
    for (let attempt = 0; attempt < 100; attempt++) {
      const metadata = JSON.parse(await readFile(path.join(savedPath, 'session.json')));
      const track = metadata.tracks.filter(track => track.kind === kind)[index];
      if (track) {
        const wav = await readFile(path.join(savedPath, track.file));
        const frames = (wav.length - 44) / (track.channels * 2);
        if (frames >= track.sampleRate * seconds) return { track, frames };
      }
      await page.waitForTimeout(100);
    }
    throw new Error('Timed out waiting for recorded source samples');
  }
  await recordedSource('local', 0, 2.5);
  host.kill('SIGSTOP');
  await page.waitForTimeout(3000);
  host.kill('SIGCONT');
  await recordedSource('local', 0, 5.5);
  await page.evaluate(async () => {
    const { context, a } = window.testAudio;
    const oscillator = context.createOscillator(); oscillator.frequency.value = 660;
    const replacement = context.createMediaStreamDestination();
    oscillator.connect(replacement); oscillator.start();
    await a.getSenders()[0].replaceTrack(replacement.stream.getAudioTracks()[0]);
    window.testAudio.replacement = replacement;
    window.testAudio.replacementOscillator = oscillator;
  });
  await recordedSource('local', 1, 2);
  await page.evaluate(async () => {
    window.restoredTrack = testAudio.a.getSenders()[0].track;
    await testAudio.a.getSenders()[0].replaceTrack(null);
  });
  await page.waitForTimeout(700);
  await page.evaluate(() => testAudio.a.getSenders()[0].replaceTrack(window.restoredTrack));
  const beforeMute = await recordedSource('local', 1, 4);
  const muteOffset = await page.evaluate(() => {
    window.testAudio.replacement.stream.getAudioTracks()[0].enabled = false;
    return Date.now() - window.recordingOrigin;
  });
  await page.waitForTimeout(800);
  // Removing the sender must not rediscover the same local track through its media preview.
  await page.evaluate(() => testAudio.a.removeTrack(testAudio.a.getSenders()[0]));
  await page.waitForTimeout(800);
  await page.evaluate(() => window.postMessage({ channel: 'cassini-control', type: 'stop', token: 'test' }, '*'));
  await page.waitForFunction(() => window.captureStopped, null, { timeout: 20000 });
  assert.deepEqual(problems, []);
  const stopped = await send({ type: 'stop' });
  assert.equal(stopped.type, 'stopped');
  const manifest = JSON.parse(await readFile(path.join(savedPath, 'session.json')));
  assert.equal(manifest.state, 'completed');
  assert.equal(manifest.tracks.length, 3);
  assert.deepEqual(manifest.tracks.map(track => track.kind).sort(), ['local', 'local', 'remote']);
  const locals = manifest.tracks.filter(track => track.kind === 'local').sort((a, b) => a.startOffsetMs - b.startOffsetMs);
  assert.ok(locals[1].startOffsetMs > 2400, 'replacement retains the shared session timeline');
  const sampleMuteOffset = locals[1].startOffsetMs + beforeMute.frames / locals[1].sampleRate * 1000;
  const clockError = Math.abs(sampleMuteOffset - muteOffset);
  assert.ok(clockError < 400, `render timeline must follow elapsed time within 400 ms; error=${clockError.toFixed(1)} ms`);
  for (const track of manifest.tracks) {
    const wav = await readFile(path.join(savedPath, track.file));
    assert.equal(wav.toString('ascii', 0, 4), 'RIFF');
    assert.equal(wav.readUInt32LE(40), wav.length - 44);
    assert.ok(track.frames > 48000, 'more than one second of audio');
    assert.ok(wav.subarray(44, wav.length - 20000).some(byte => byte !== 0), `${track.kind}: audible generated tone`);
    if (track.id === locals[1].id) assert.ok(wav.subarray(-12000).every(byte => byte === 0), 'muted sender becomes silence');
    if (track.id === locals[1].id) {
      const first = beforeMute.frames + Math.round(track.sampleRate * 0.2);
      const last = beforeMute.frames + Math.round(track.sampleRate * 0.5);
      assert.ok(last < track.frames, 'measured mute window is present');
      const interval = wav.subarray(44 + first * 2, 44 + last * 2);
      assert.ok(interval.every(byte => byte === 0), 'mute is silent at the persisted sample position');
    }
    const expected = track.kind === 'remote' ? 880 : (track.id === locals[0].id ? 440 : 660);
    const { first, count } = toneWindow(wav, track.sampleRate);
    const power = frequency => tonePower(wav, track.sampleRate, frequency, first, count);
    assert.ok(power(expected) > 0.001, `source contains ${expected} Hz`);
    for (const other of [440, 660, 880].filter(tone => tone !== expected)) {
      assert.ok(power(other) < power(expected) * 0.01, `${track.kind}: ${other} Hz bleed below one percent`);
    }
  }
  console.log(`PASS: real WebRTC → AudioWorklet → native host → ${manifest.tracks.length} WAV tracks (${packets.length} packets), including replacement, mute, sender removal and stop/flush; clock error ${clockError.toFixed(1)} ms.`);
} catch (error) {
  await saveFailure('synthetic-capture', error, savedPath);
  throw error;
} finally {
  host.kill('SIGCONT');
  await browser?.close(); host.stdin.end(); host.kill(); server.close();
  if (savedPath) await rm(savedPath, { recursive: true, force: true });
}
