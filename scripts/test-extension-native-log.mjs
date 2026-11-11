#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Regression for extension-native-log.mjs (D66 mac-P0-1): a native disconnect and its lastError
// stay recorded after the service worker that saw them is gone: they are kept in Node as they
// happen, never read back from the worker.
import assert from 'node:assert/strict';
import {mkdtemp, writeFile, rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createRequire} from 'node:module';
import {attachNativeLog} from './extension-native-log.mjs';
const require = createRequire(path.resolve('BrowserExtension/tests/package.json'));
const {chromium} = require('playwright');
const base = await mkdtemp(path.join(os.tmpdir(),'native-log-'));
const extension = path.join(base,'extension');
await (await import('node:fs/promises')).mkdir(extension);
await writeFile(path.join(extension,'manifest.json'),JSON.stringify({manifest_version:3,name:'native log',version:'1',permissions:['nativeMessaging'],background:{service_worker:'worker.js'}}));
// The worker connects on request, to a host that does not exist: Chromium disconnects it with a
// lastError. It first sends one audio message on the port, as the extension does.
await writeFile(path.join(extension,'worker.js'),"self.connectMissing = () => { const port = chrome.runtime.connectNative('io.codemyriad.cassini.missing-host');" +
  " try { port.postMessage({type:'audio',id:'source-1',sequence:3,offsetMs:12.6,pcm:'AAAA'}); } catch {} };\n");
let context;
try {
  context = await chromium.launchPersistentContext(path.join(base,'profile'),{channel:'chromium',headless:true,
    args:[`--disable-extensions-except=${extension}`,`--load-extension=${extension}`]});
  const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
  const log = attachNativeLog(context);
  await log.ready;
  const disconnected = log.waitForEvent('disconnect',{signal:AbortSignal.timeout(10000)});
  await Promise.all([disconnected,worker.evaluate(() => self.connectMissing())]);
  // The browser goes away, and every worker with it: nothing is read back from a worker, so the
  // events recorded while they happened are all still here.
  await context.close(); context = undefined;
  const disconnect = log.events.find(e => e.event === 'disconnect');
  assert.ok(log.events.some(e => e.event === 'connect'),JSON.stringify(log.events));
  assert.ok(disconnect && typeof disconnect.error === 'string' && disconnect.error.length > 0,JSON.stringify(log.events));
  // What the worker sends is logged with its fields, never its PCM, and every entry carries the
  // worker's own time next to Node's receipt time.
  const sent = log.events.find(e => e.event === 'sent');
  assert.deepEqual(sent && {type:sent.type,id:sent.id,sequence:sent.sequence,offsetMs:sent.offsetMs,pcm:sent.pcm},
    {type:'audio',id:'source-1',sequence:3,offsetMs:13,pcm:undefined},JSON.stringify(log.events));
  assert.ok(log.events.filter(e => e.worker).every(e => Number.isFinite(e.t) && Number.isFinite(e.at)),JSON.stringify(log.events));
  console.log('PASS native connect and disconnect with lastError survive their worker ending');
} finally {
  await context?.close(); await rm(base,{recursive:true,force:true});
}
