// SPDX-License-Identifier: GPL-3.0-or-later
// Shared test 2 (D68): the protocol live-folder driver (browser-protocol/scenarios/live-folder.mjs)
// against the real app, real Chromium and the loaded extension, on disposable hosted Macs only.
// The folder is judged by browser-protocol/conformance/live-folder/check.py, run by the driver.
//
// The app adapter: the app runs --live-folder-self-test (Cassini/Browser/LiveFolderSelfTest.swift)
// and answers one JSON command per line. Its native sides are the guarded RAM fixture (a 440 Hz
// microphone tone, no devices). The driver's launchers register the app's production hosts
// (scenarios/native-launcher.mjs: the audio host's pid recorded, the control host observed on its
// pipe), and the app never runs companion setup, so nothing rewrites those registrations.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { attachNativeLog } from './extension-native-log.mjs';

assert.equal(process.env.GITHUB_ACTIONS, 'true');
assert.equal(process.env.RUNNER_ENVIRONMENT, 'github-hosted', 'Never run on a user desktop');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const protocol = path.join(root, 'browser-protocol');
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || '../BrowserExtension/tests/node_modules/playwright/index.mjs');
const { runLiveFolder } = await import(path.join(protocol, 'scenarios/live-folder.mjs'));
const { livePids, writeNativeHost } = await import(path.join(protocol, 'scenarios/native-launcher.mjs'));

const source = path.resolve(process.argv[2]), out = path.resolve(process.argv[3]);
const EXTENSION = 'pcafdaahfhjiolfpfnlhmljfgoabbaij', ORIGIN = `chrome-extension://${EXTENSION}/`;
const MIC_HZ = 440;  // CaptureFixture's generated microphone
const base = await mkdtemp(path.join(root, 'build/live-folder-'));
const app = path.join(base, 'Installed Cassini.app');
const profile = path.join(os.userInfo().homedir, 'Library/Application Support/Google/Chrome for Testing');
// The app's sandbox reads its control pipes here; LiveFolderSelfTest.controlRoot checks the name.
const controlRoot = path.join(os.userInfo().homedir, 'Library/Containers/io.codemyriad.cassini/Data/tmp', path.basename(base), 'control');

// The two pages: the meeting (in the browser with the extension) and its far end (a second,
// plain browser, so the extension never sees the far end as a call).
const server = http.createServer((request, response) => {
  response.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
  response.end(`<!doctype html><title>${request.url === '/remote' ? 'Far end' : 'Live folder call'}</title><body>`);
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${server.address().port}`;

let ownsProfile = false, context = null, remoteBrowser = null, child = null, exited = false, stdout = '', stderr = '';
const pending = new Map(), lines = [];
let next = 0, ready = null, cleaned = null, code = 1, sampler = null, nativeLog = null;
const clock = [], load = [];

function launchApp(env) {
  child = spawn(path.join(app, 'Contents/MacOS/Cassini'), [
    '--live-folder-self-test', '--fixture-library-recording', '-CassiniCaptureID', crypto.randomUUID(),
    '-CassiniDiskFree', String(20 * 2 ** 30), '-CassiniDiskTotal', String(100 * 2 ** 30), '-ApplePersistenceIgnoreState', 'YES',
  ], { env, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
  let buffer = '';
  child.stdout.on('data', data => {
    stdout += data; buffer += data;
    for (let at = buffer.indexOf('\n'); at >= 0; at = buffer.indexOf('\n')) {
      const line = buffer.slice(0, at); buffer = buffer.slice(at + 1);
      let message; try { message = JSON.parse(line); } catch { continue; }
      if (message.phase === 'ready') { ready?.resolve(message); continue; }
      const waiter = pending.get(message.id);
      if (!waiter) continue;
      pending.delete(message.id);
      message.ok ? waiter.resolve(message.value) : waiter.reject(new Error(`app ${waiter.command}: ${message.error}`));
    }
  });
  child.stderr.on('data', data => { stderr += data; });
  child.on('exit', (status, signal) => {
    exited = true;
    const error = new Error(`the app exited (${status ?? signal})`);
    ready?.reject(error);
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
  });
}
// One command, answered once the app has acted (each driver wait is bounded by the driver).
function command(name, extra = {}) {
  if (exited) return Promise.reject(new Error(`app ${name}: the app has exited`));
  const id = ++next;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject, command: name });
    child.stdin.write(JSON.stringify({ id, command: name, ...extra }) + '\n');
  });
}
const bounded = (promise, ms, label) => Promise.race([promise, new Promise((_, reject) => setTimeout(() => reject(new Error(`${label} took over ${ms} ms`)), ms).unref())]);
// The browser process that runs the extension: Playwright starts it as this process's own child.
function browserProcess() {
  const rows = execFileSync('ps', ['-ww', '-axo', 'pid=,ppid=,args='], { encoding: 'utf8' }).split('\n');
  const found = rows.map(row => row.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/)).filter(Boolean)
    .filter(([, , ppid, args]) => Number(ppid) === process.pid && args.includes('Google Chrome for Testing') && !args.includes('--type=')
      && args.includes(`--user-data-dir=${profile}`));
  assert.equal(found.length, 1, `one Chrome for Testing process with this profile is this process's child: ${JSON.stringify(found.map(f => f[0]))}`);
  return Number(found[0][1]);
}

// Ends everything this run started, once: the app, both browsers (which end the native hosts and
// their relays' input), the page server and the profile. The driver's own teardown then stops any
// relay or waiting launcher left; it keeps controlHost.observe for the evidence.
async function cleanup() {
  cleaned ??= (async () => {
    clearInterval(sampler);
    if (child && !exited) {
      try { await bounded(command('quit'), 15000, 'quit'); } catch {}
      if (!exited) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
    }
    await context?.close().catch(() => {});
    await remoteBrowser?.close().catch(() => {});
    server.close();
    if (ownsProfile) await rm(profile, { recursive: true, force: true }).catch(() => {});
  })();
  return cleaned;
}

try {
  await assert.rejects(stat(profile), { code: 'ENOENT' }, 'Requires a fresh disposable profile');
  await mkdir(profile, { recursive: true }); ownsProfile = true;
  await mkdir(controlRoot, { recursive: true, mode: 0o700 });
  await mkdir(out, { recursive: true });
  execFileSync('ditto', [source, app]);
  execFileSync('codesign', ['--verify', '--deep', '--strict', app]);
  const manifests = path.join(profile, 'NativeMessagingHosts');
  const audio = await writeNativeHost({ manifestDirectory: manifests, launcherDirectory: path.join(base, 'launchers'), pidDirectory: path.join(base, 'pids'),
    name: 'io.codemyriad.cassini', command: [path.join(app, 'Contents/MacOS/cassini-browser-host')], allowedOrigins: [ORIGIN] });
  const control = await writeNativeHost({ manifestDirectory: manifests, launcherDirectory: path.join(base, 'launchers'), pidDirectory: path.join(base, 'pids'),
    name: 'io.codemyriad.cassini.control', command: [path.join(app, 'Contents/MacOS/cassini-control-host')], allowedOrigins: [ORIGIN],
    observe: path.join(base, 'control-pipe') });
  const env = { ...process.env, CASSINI_CONTROL_PIPE_ROOT: controlRoot, CASSINI_HOSTED_SCREENSHOTS: '1' };
  const chromiumApp = chromium.executablePath().split('/Contents/')[0];
  execFileSync('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', ['-f', chromiumApp]);
  // Production defaults. D68.1 (protocol #54, extension 0.2.13) keeps each capture context's output
  // non-silent, so Chromium never moves it onto the slow timer that broke this test on hosted Macs.
  // The clock and load evidence below stays, so a regression shows its rate.
  const callArgs = ['--autoplay-policy=no-user-gesture-required', '--allow-loopback-in-peer-connection', '--disable-features=WebRtcHideLocalIpsWithMdns'];
  try { await writeFile(path.join(out, 'audio-devices.json'), execFileSync('system_profiler', ['SPAudioDataType', '-json'], { encoding: 'utf8' })); } catch {}
  // The app first, so its control pipe root is served when the extension's control host connects.
  const started = new Promise((resolve, reject) => { ready = { resolve, reject }; });
  launchApp(env);
  const { libraryRoot } = await bounded(started, 60000, 'the app becoming ready');
  context = await chromium.launchPersistentContext(profile, { channel: 'chromium', headless: true, env,
    args: [`--disable-extensions-except=${root}/BrowserExtension`, `--load-extension=${root}/BrowserExtension`, ...callArgs] });
  const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
  assert.equal(new URL(worker.url()).host, EXTENSION);
  // D66 mac-P0-1: the extension's native traffic (worker-stamped, error codes, what it sends,
  // worker restarts), kept in Node: a #153 run lost A for 11 s while the worker answered late.
  nativeLog = attachNativeLog(context);
  await nativeLog.ready;
  remoteBrowser = await chromium.launch({ headless: true, args: callArgs });
  const remote = await remoteBrowser.newPage();
  await remote.goto(`${url}/remote`);
  const meeting = await context.newPage();
  await meeting.goto(`${url}/meeting`);
  const browserPid = browserProcess();
  // Evidence: each page's audio render clock against wall time, sampled every 2 s (a sampler,
  // never a wait). A rate under 1 is a stalling output device.
  // Each probe keeps its output non-silent as the extension does (D68.1), so it reads the device
  // clock, not the silent-sink timer a silent probe would fall onto after 30 s.
  for (const page of [meeting, remote]) await page.evaluate(async () => {
    const probe = window.cassiniClockProbe = new AudioContext(), keep = probe.createConstantSource();
    keep.offset.value = 6e-8; keep.connect(probe.destination); keep.start(); await probe.resume();
  });
  const sample = async page => page.evaluate(() => ({ audio: window.cassiniClockProbe?.currentTime ?? null, state: window.cassiniClockProbe?.state ?? null })).catch(() => null);
  sampler = setInterval(async () => {
    // wall (Date.now) and monotonic (performance.now) together: the driver's session clock is the
    // wall clock, the apps' events the monotonic one, so their drift is evidence too.
    clock.push({ wall: Date.now(), monotonic: performance.now(), meeting: await sample(meeting), remote: await sample(remote) });
    // Every 10 s: the load average and the top CPU users (evidence for a slow render clock).
    if (clock.length % 5 === 1) {
      try { load.push({ wall: Date.now(), uptime: execFileSync('uptime', { encoding: 'utf8' }).trim(),
        top: execFileSync('ps', ['-axro', 'pid,pcpu,rss,comm'], { encoding: 'utf8' }).split('\n').slice(0, 14) }); } catch {}
    }
  }, 2000);

  const adapter = {
    name: 'macos',
    protocolCommit: (await readFile(path.join(protocol, 'PINNED_COMMIT'), 'utf8')).trim(),
    nativeTones: { microphone: MIC_HZ },
    record: () => command('record'),
    selectMe: on => command('selectMe', { on }),
    snapshot: () => command('snapshot'),
    meetingRow: () => command('meetingRow'),
    stop: () => command('stop'),
    saved: () => bounded(command('saved'), 65000, 'saving after Stop'),
    audioHostPids: () => livePids(audio),
    folders: async () => {
      try { return (await readdir(libraryRoot)).filter(name => name.startsWith('Recording-')); }
      catch (error) { if (error.code === 'ENOENT') return []; throw error; }
    },
    controlHost: control,
    browserPid: async () => browserPid,
    cleanup: ({ failed }) => { if (failed) process.stderr.write('live-folder: the run failed; tearing down\n'); return cleanup(); },
  };
  const result = await runLiveFolder({ meeting, remote, app: adapter, worker, out });
  await writeFile(path.join(out, 'run.json'), JSON.stringify({ code: result.code, folder: result.folder, result: result.result,
    nativeArchitecture: os.arch(), realChromium: true, realExtension: true, nativeInputsGenerated: true }, null, 1) + '\n');
  code = result.code;
  console.log(code === 0 ? 'PASS shared test 2 (live folder): check.py passed on the real app\'s folder' : `FAIL shared test 2: check.py exited ${code}`);
} catch (error) {
  console.error(error.stack || String(error));
  code = 1;
} finally {
  clearInterval(sampler);
  await cleanup();
  // Render-clock rate per page: audio seconds per wall second between the first and last sample.
  const rate = key => {
    const points = clock.filter(c => typeof c[key]?.audio === 'number');
    if (points.length < 2) return null;
    const [a, b] = [points[0], points.at(-1)];
    return (b[key].audio - a[key].audio) / ((b.wall - a.wall) / 1000);
  };
  // Wall minus monotonic, from the first sample to the last (ms): the wall clock's slew over the run.
  const drift = clock.length > 1 ? (clock.at(-1).wall - clock[0].wall) - (clock.at(-1).monotonic - clock[0].monotonic) : null;
  await writeFile(path.join(out, 'audio-clock.json'), JSON.stringify({ rate: { meeting: rate('meeting'), remote: rate('remote') }, wallMinusMonotonicMs: drift, samples: clock }, null, 1) + '\n').catch(() => {});
  console.log(`live-folder: wall clock minus monotonic clock over the run ${drift?.toFixed(1)} ms`);
  await writeFile(path.join(out, 'load.json'), JSON.stringify(load, null, 1) + '\n').catch(() => {});
  console.log(`live-folder: audio render clock rate meeting ${rate('meeting')?.toFixed(3)} remote ${rate('remote')?.toFixed(3)}`);
  if (nativeLog) await writeFile(path.join(out, 'extension.json'), JSON.stringify({ events: nativeLog.events }, null, 1) + '\n').catch(() => {});
  await writeFile(path.join(out, 'app.stdout.txt'), stdout).catch(() => {});
  await writeFile(path.join(out, 'app.stderr.txt'), stderr).catch(() => {});
}
process.exit(code);
