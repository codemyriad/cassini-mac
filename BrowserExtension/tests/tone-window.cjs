// SPDX-License-Identifier: GPL-3.0-or-later
const assert = require('node:assert/strict');

// Web Audio's MediaStream bridge may initially supply silence while its render
// threads start. Find activity, not the expected frequency, so a wrong source
// still fails the caller's unchanged spectral and isolation assertions.
exports.toneWindow = function toneWindow(wav, sampleRate) {
  const frames = (wav.length - 44) / 2;
  const startupLimit = Math.min(frames, sampleRate);
  let active = 0;
  while (active < startupLimit && Math.abs(wav.readInt16LE(44 + active * 2)) < 327) active++;
  assert.ok(active < startupLimit, 'generated source becomes audible within one second');
  const first = active + Math.round(sampleRate * 0.1);
  const count = 12000;
  assert.ok(first + count <= frames, 'complete steady-source analysis window is present');
  return { first, count };
};
