// SPDX-License-Identifier: GPL-3.0-or-later
// Event-order checks: inert workers only, no Chromium, native host or devices.
import assert from 'node:assert/strict';
import {EventEmitter, getEventListeners} from 'node:events';
import test from 'node:test';
import {attachNativeLog} from './extension-native-log.mjs';

class Worker extends EventEmitter {
  url() { return 'chrome-extension://private/worker.js'; }
  async evaluate() {}
  send(event) { this.emit('console',{text:() => 'cassini-native '+JSON.stringify(event)}); }
}
function fixture(options) {
  const worker = new Worker(), context = new EventEmitter();
  context.serviceWorkers = () => [worker];
  return {worker,context,log:attachNativeLog(context,options)};
}

test('only the matching recorded event completes a wait and removes its abort listener',async () => {
  const {worker,log} = fixture(); await log.ready;
  const control = new AbortController(); let completed = false;
  const waiting = log.waitForEvent('disconnect',{signal:control.signal}).then(event => { completed=true; return event; });
  worker.send({event:'sent',type:'audio'});
  await Promise.resolve(); assert.equal(completed,false);
  assert.equal(getEventListeners(control.signal,'abort').length,1);
  worker.send({event:'disconnect',error:'Missing private host'});
  assert.equal((await waiting).error,'Missing private host');
  assert.equal(getEventListeners(control.signal,'abort').length,0);
  worker.emit('close');
  assert.equal((await log.waitForEvent('disconnect')).error,'Missing private host');
});

test('existing events, multiple waiters and a replacement worker retain their identity',async () => {
  const {worker,context,log} = fixture(); await log.ready;
  const first = log.waitForEvent('disconnect'), second = log.waitForEvent('disconnect');
  worker.send({event:'disconnect',error:'Original private worker'});
  const recorded = await first; assert.equal(await second,recorded);
  const replacement = new Worker(); context.emit('serviceworker',replacement);
  const next = log.waitForEvent('message');
  replacement.send({event:'message',type:'status'});
  assert.equal((await next).type,'status');
  assert.equal(await log.waitForEvent('disconnect'),recorded);
});

test('an abort rejects rather than establishing event absence',async () => {
  const {log} = fixture(); await log.ready;
  const control = new AbortController(), reason = new Error('Manual hang guard');
  const waiting = log.waitForEvent('disconnect',{signal:control.signal});
  control.abort(reason);
  await assert.rejects(waiting,error => error === reason);
  assert.equal(getEventListeners(control.signal,'abort').length,0);
  await assert.rejects(log.waitForEvent('disconnect',{signal:control.signal}),error => error === reason);
});

test('the retained-event limit cannot create a false completion',async () => {
  const {worker,log} = fixture({limit:1}); await log.ready; // The worker entry fills it.
  const control = new AbortController(); let completed = false;
  const waiting = log.waitForEvent('disconnect',{signal:control.signal}).then(() => { completed=true; });
  worker.send({event:'disconnect',error:'Outside retained log'});
  await Promise.resolve(); assert.equal(completed,false);
  assert.equal(log.events.length,1);
  control.abort(); await assert.rejects(waiting,{name:'AbortError'});
});
