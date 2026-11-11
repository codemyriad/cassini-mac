// SPDX-License-Identifier: GPL-3.0-or-later
// D66 mac-P0-1: diagnostics for a Chromium extension's native messaging, collected in Node as
// they happen. Each service worker of the context is instrumented: every connectNative, every
// disconnect with chrome.runtime.lastError, message types, worker errors and rejections are sent
// out through the worker's console, so they survive the worker closing or restarting (the
// case these diagnostics exist to explain). Diagnostics only: the extension's own code and
// behaviour are unchanged, and a failure to instrument is recorded instead of thrown.
// Each entry carries `at` (when Node received it) and `t` (the worker's own Date.now() when it
// happened): a backlog between them showed up in a failure. The app's `error` replies keep their
// code, scope, id and message, and what the worker sends is logged too (type, id, sequence and
// offset; never PCM), so a refused returning source names its refusal.
const PREFIX = 'cassini-native ';
export function attachNativeLog(context, {limit = 20000} = {}) {
  const events = [];
  const listeners = new Set();
  const note = entry => {
    if (events.length >= limit) return;
    const recorded = {at:Date.now(),...entry}; events.push(recorded);
    for (const listener of listeners) listener(recorded);
  };
  const waitForEvent = (event, {signal} = {}) => new Promise((resolve,reject) => {
    if (signal?.aborted) { reject(signal.reason); return; }
    const recorded = events.find(entry => entry.event === event);
    if (recorded) { resolve(recorded); return; }
    const cleanup = () => { listeners.delete(receive); signal?.removeEventListener('abort',abort); };
    const receive = entry => { if (entry.event === event) { cleanup(); resolve(entry); } };
    const abort = () => { cleanup(); reject(signal.reason); };
    listeners.add(receive); signal?.addEventListener('abort',abort,{once:true});
  });
  const instrument = async worker => {
    const url = worker.url();
    note({event:'worker',url});
    worker.on('close',() => note({event:'worker-closed',url}));
    worker.on('console',message => {
      const text = message.text();
      if (!text.startsWith(PREFIX)) return;
      try { note({worker:url,...JSON.parse(text.slice(PREFIX.length))}); } catch { note({worker:url,event:'unreadable',text}); }
    });
    await worker.evaluate(prefix => {
      if (globalThis.__cassiniNativeLog) return;
      globalThis.__cassiniNativeLog = true;
      const send = entry => console.debug(prefix + JSON.stringify({t:Date.now(),...entry}));
      const fields = message => {
        if (!message || typeof message !== 'object') return {type:typeof message};
        const entry = {type:message.type};
        for (const key of ['id','sequence','code','scope','retired']) if (message[key] !== undefined) entry[key] = message[key];
        if (Number.isFinite(message.offsetMs)) entry.offsetMs = Math.round(message.offsetMs);
        if (message.type === 'error' && message.message !== undefined) entry.message = String(message.message).slice(0,200);
        return entry;
      };
      const connect = chrome.runtime.connectNative.bind(chrome.runtime);
      chrome.runtime.connectNative = name => {
        const port = connect(name); send({event:'connect',name});
        port.onDisconnect.addListener(() => send({event:'disconnect',name,error:chrome.runtime.lastError?.message ?? null}));
        port.onMessage.addListener(message => send({event:'message',name,...fields(message)}));
        const post = port.postMessage.bind(port);
        port.postMessage = message => { send({event:'sent',name,...fields(message)}); return post(message); };
        return port;
      };
      self.addEventListener('error',event => send({event:'error',message:String(event.message)}));
      self.addEventListener('unhandledrejection',event => send({event:'rejection',message:String(event.reason)}));
    },PREFIX).catch(error => note({event:'instrument-failed',url,message:String(error)}));
  };
  const ready = Promise.all(context.serviceWorkers().map(instrument));
  context.on('serviceworker',worker => { void instrument(worker); });
  return {events,ready,waitForEvent};
}
