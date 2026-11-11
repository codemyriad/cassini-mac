// SPDX-License-Identifier: GPL-3.0-or-later
// Observe state transitions; the timer can only reject a hung observation.
export function waitForChange({predicate, subscribe, failure = () => null,
                               diagnostic, timeout = 45000, timers = globalThis}) {
 return new Promise((resolve, reject) => {
  let settled = false, timer, unsubscribe = () => {};
  const finish = error => {
   if (settled) return;
   settled = true;
   if (timer !== undefined) timers.clearTimeout(timer);
   unsubscribe();
   if (error) reject(error); else resolve();
  };
  const changed = () => {
   try {
    if (predicate()) finish();
    else {
     const error = failure();
     if (error) finish(error);
    }
   } catch (error) { finish(error); }
  };
  try {
   // Subscribe before inspecting state, including synchronous notification.
   unsubscribe = subscribe(changed);
   if (settled) { unsubscribe(); return; }
   timer = timers.setTimeout(() => {
    try { finish(new Error(diagnostic())); }
    catch (error) { finish(error); }
   }, timeout);
   changed();
  } catch (error) { finish(error); }
 });
}
