// SPDX-License-Identifier: GPL-3.0-or-later
// Disposable GitHub-hosted profile only. No capture APIs, page clicks or mocked native transport.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile, stat, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

assert.equal(process.env.GITHUB_ACTIONS, 'true');
assert.equal(process.env.RUNNER_ENVIRONMENT, 'github-hosted', 'Never run on a user desktop');
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || '../BrowserExtension/tests/node_modules/playwright/index.mjs');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = path.resolve(process.argv[2]);
const output = path.resolve(process.argv[3]);
const base = await mkdtemp(path.join(root, 'build/browser-background-'));
const app = path.join(base, 'Installed Cassini.app');
// The production installer uses the account home (not a sandbox's HOME).
// Playwright's pinned Chromium distribution is Chrome for Testing, with its
// own installed bundle ID and default registration root. Never impersonate an
// installed Chromium app or bypass the production installer's app discovery.
const profile = path.join(os.userInfo().homedir, 'Library/Application Support/Google/Chrome for Testing');
const manifests = path.join(profile, 'NativeMessagingHosts');
const hosts = ['io.codemyriad.cassini', 'io.codemyriad.cassini.control'];
const controlRoot = path.join(os.userInfo().homedir, 'Library/Containers/io.codemyriad.cassini/Data/tmp', path.basename(base), 'control');
let ownsProfile = false;
let context, child;
let stdout = '', stderr = '';
try {
  await assert.rejects(stat(profile), { code: 'ENOENT' }, 'This job must start with a fresh Chromium profile');
  await mkdir(profile, { recursive: true }); ownsProfile = true;
  await mkdir(controlRoot, { recursive: true, mode: 0o700 });
  await mkdir(path.dirname(output), { recursive: true });
  execFileSync('ditto', [source, app]);
  execFileSync('codesign', ['--verify', '--deep', '--strict', app]);
  const env = { ...process.env, CASSINI_CONTROL_PIPE_ROOT: controlRoot, CASSINI_HOSTED_SCREENSHOTS: '1' };
  // Treat the downloaded Chromium app as installed in Launch Services, while
  // keeping its disposable profile and all interactions on this hosted runner.
  const chromiumApp = chromium.executablePath().split('/Contents/')[0];
  const browserInfo = JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', path.join(chromiumApp, 'Contents/Info.plist')], { encoding: 'utf8' }));
  assert.equal(browserInfo.CFBundleIdentifier, 'com.google.chrome.for.testing');
  execFileSync('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', ['-f', chromiumApp]);
  context = await chromium.launchPersistentContext(profile, {
    channel: 'chromium', headless: true, env,
    args: [`--disable-extensions-except=${root}/BrowserExtension`, `--load-extension=${root}/BrowserExtension`]
  });
  const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
  assert.equal(new URL(worker.url()).host, 'pcafdaahfhjiolfpfnlhmljfgoabbaij');
  // The extension is already waiting/retrying when the installed app starts.
  for (const host of hosts) await assert.rejects(stat(path.join(manifests, host + '.json')), { code: 'ENOENT' });
  child = spawn(path.join(app, 'Contents/MacOS/Cassini'), ['--browser-background-self-test', '-ApplePersistenceIgnoreState', 'YES'], { env, detached: true });
  child.stdout.on('data', data => { stdout += data; }); child.stderr.on('data', data => { stderr += data; });
  const code = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Installed app did not connect in 95 seconds')), 95000);
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('exit', code => { clearTimeout(timer); resolve(code); });
  });
  assert.equal(code, 0, `${stdout}\n${stderr}`);
  const report = JSON.parse(stdout);
  assert.equal(report.connectedWithoutClick, true); assert.equal(report.uiActions, 0);
  assert.equal(report.capturedAudio, false); assert.match(report.state, /^Connected/);
  assert.equal(report.localCompanionPrepared, true);
  for (const [index, host] of hosts.entries()) {
    const manifest = JSON.parse(await readFile(path.join(manifests, host + '.json'), 'utf8'));
    assert.equal(manifest.name, host);
    assert.deepEqual(manifest.allowed_origins, ['chrome-extension://pcafdaahfhjiolfpfnlhmljfgoabbaij/']);
    assert.equal(manifest.path, path.join(app, 'Contents/MacOS', index === 0 ? 'cassini-browser-host' : 'cassini-control-host'));
  }
  report.installedAtChangedPath = true; report.freshProfile = true; report.realExtension = true; report.browserBundleID = browserInfo.CFBundleIdentifier;
  report.nativeArchitecture = os.arch();
  await writeFile(output, JSON.stringify(report, null, 2) + '\n');
  console.log('PASS installed app background setup: fresh profile, real extension, no click, no recording');
} finally {
  await mkdir(path.dirname(output), { recursive: true });
  await writeFile(output + '.stderr.txt', stderr);
  if (child && child.exitCode === null) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
  await context?.close();
  // Only our disposable hosted profile and staged copy are removed.
  if (ownsProfile) await rm(profile, { recursive: true, force: true });
  await rm(path.dirname(controlRoot), { recursive: true, force: true });
  await rm(base, { recursive: true, force: true });
}
