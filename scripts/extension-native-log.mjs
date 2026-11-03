// SPDX-License-Identifier: GPL-3.0-or-later
// D66 mac-P0-1: diagnostics for a Chromium extension's native messaging, collected in Node as
// they happen. Each service worker of the context is instrumented: every connectNative, every
// disconnect with chrome.runtime.lastError, message types, worker errors and rejections are sent
// out through the worker's console, so they survive the worker closing or restarting (the
// case these diagnostics exist to explain). Diagnostics only: the extension's own code and
// behaviour are unchanged, and a failure to instrument is recorded instead of thrown.
const PREFIX = 'cassini-native ';
export function attachNativeLog(context, {limit = 5000} = {}) {
  const events = [];
  const note = entry => { if (events.length < limit) events.push({at:Date.now(),...entry}); };
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
      const send = entry => console.debug(prefix + JSON.stringify(entry));
      const connect = chrome.runtime.connectNative.bind(chrome.runtime);
      chrome.runtime.connectNative = name => {
        const port = connect(name); send({event:'connect',name});
        port.onDisconnect.addListener(() => send({event:'disconnect',name,error:chrome.runtime.lastError?.message ?? null}));
        port.onMessage.addListener(message => send({event:'message',name,type:message?.type ?? typeof message}));
        return port;
      };
      self.addEventListener('error',event => send({event:'error',message:String(event.message)}));
      self.addEventListener('unhandledrejection',event => send({event:'rejection',message:String(event.reason)}));
    },PREFIX).catch(error => note({event:'instrument-failed',url,message:String(error)}));
  };
  const ready = Promise.all(context.serviceWorkers().map(instrument));
  context.on('serviceworker',worker => { void instrument(worker); });
  return {events,ready};
}
