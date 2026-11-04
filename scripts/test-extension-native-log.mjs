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
// The worker connects on request, to a host that does not exist: Chromium disconnects it with a lastError.
await writeFile(path.join(extension,'worker.js'),"self.connectMissing = () => chrome.runtime.connectNative('io.codemyriad.cassini.missing-host');\n");
let context;
try {
  context = await chromium.launchPersistentContext(path.join(base,'profile'),{channel:'chromium',headless:true,
    args:[`--disable-extensions-except=${extension}`,`--load-extension=${extension}`]});
  const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
  const log = attachNativeLog(context);
  await log.ready;
  const disconnected = new Promise(resolve => {
    const check = () => log.events.some(e => e.event === 'disconnect') ? resolve() : setTimeout(check,10);
    check();
  });
  await worker.evaluate(() => self.connectMissing());
  await Promise.race([disconnected,new Promise((_,reject) => setTimeout(() => reject(new Error('no disconnect')),10000))]);
  // The browser goes away, and every worker with it: nothing is read back from a worker, so the
  // events recorded while they happened are all still here.
  await context.close(); context = undefined;
  const disconnect = log.events.find(e => e.event === 'disconnect');
  assert.ok(log.events.some(e => e.event === 'connect'),JSON.stringify(log.events));
  assert.ok(disconnect && typeof disconnect.error === 'string' && disconnect.error.length > 0,JSON.stringify(log.events));
  console.log('PASS native connect and disconnect with lastError survive their worker ending');
} finally {
  await context?.close(); await rm(base,{recursive:true,force:true});
}
