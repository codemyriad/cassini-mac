// SPDX-License-Identifier: GPL-3.0-or-later
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import test from 'node:test';
import {waitForChange} from './wait-for-change.mjs';

function fixture() {
 const events = new EventEmitter(), pending = new Map();
 let next = 0, scheduled = 0;
 const timers = {
  setTimeout(callback, timeout) { assert.equal(timeout,45000); pending.set(++next,callback); scheduled++; return next; },
  clearTimeout(id) { pending.delete(id); }
 };
 const wait = (predicate, failure = () => null) => waitForChange({predicate,failure,timers,
  subscribe: listener => { events.on('change',listener); return () => events.off('change',listener); },
  diagnostic: () => 'missing phase; retained output'
 });
 const clean = () => { assert.equal(events.listenerCount('change'),0); assert.equal(pending.size,0); };
 return {wait,events,pending,clean,timers,scheduled:() => scheduled};
}

test('retained phase resolves without waiting for another event', async () => {
 const f=fixture();await f.wait(() => true);f.clean();
});

test('output event releases the wait without firing any timer', async () => {
 const f=fixture();let ready=false,reads=0;
 const result=f.wait(() => {reads++;return ready;});
 assert.equal(reads,1);assert.equal(f.pending.size,1);
 ready=true;f.events.emit('change');await result;
 assert.equal(reads,2);assert.equal(f.scheduled(),1);f.clean();
});

test('unrelated output keeps observing without scheduling polling timers', async () => {
 const f=fixture();let ready=false,done=false;
 const result=f.wait(() => ready).then(() => {done=true;});
 f.events.emit('change');await Promise.resolve();assert.equal(done,false);
 assert.equal(f.scheduled(),1);assert.equal(f.events.listenerCount('change'),1);
 ready=true;f.events.emit('change');await result;f.clean();
});

test('process failure rejects immediately and releases observation', async () => {
 const f=fixture();let error;
 const result=f.wait(() => false,() => error);
 const rejected=assert.rejects(result,/child failed/);
 error=new Error('child failed');f.events.emit('change');await rejected;f.clean();
});

test('exit does not reject a buffered phase before streams close', async () => {
 const f=fixture();let phase=false,closed=false;
 const result=f.wait(() => phase,() => closed ? new Error('missing terminal phase'):null);
 f.events.emit('change'); // exit notification; stdout can still drain
 phase=true;f.events.emit('change');closed=true;f.events.emit('change');
 await result;f.clean();
});

test('clean EOF without the expected phase rejects instead of passing on absence', async () => {
 const f=fixture();let closed=false;
 const result=f.wait(() => false,() => closed ? new Error('app finished (0)'):null);
 const rejected=assert.rejects(result,/app finished \(0\)/);
 closed=true;f.events.emit('change');await rejected;f.clean();
});

test('hang guard only rejects, even if state changes without its event', async () => {
 const f=fixture();let ready=false;
 const result=f.wait(() => ready);const rejected=assert.rejects(result,/missing phase; retained output/);
 ready=true;[...f.pending.values()][0]();await rejected;f.clean();
});

test('concurrent phase observers remove only their own listeners and timers', async () => {
 const f=fixture();let phase=0;
 const first=f.wait(() => phase>=1),second=f.wait(() => phase>=2);
 phase=1;f.events.emit('change');await first;
 assert.equal(f.pending.size,1);assert.equal(f.events.listenerCount('change'),1);
 phase=2;f.events.emit('change');await second;f.clean();
});

test('synchronous subscription notification cannot leak the listener', async () => {
 const f=fixture();let removed=false;
 await waitForChange({predicate:() => true,diagnostic:() => 'unused',timers:f.timers,
  subscribe: listener => {listener();return () => {removed=true;};}});
 assert.equal(removed,true);assert.equal(f.scheduled(),0);f.clean();
});

test('predicate exceptions reject and clean up', async () => {
 const f=fixture();await assert.rejects(f.wait(() => {throw new Error('bad report');}),/bad report/);f.clean();
});
