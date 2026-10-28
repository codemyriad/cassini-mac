// SPDX-License-Identifier: GPL-3.0-or-later
const assert = require('node:assert/strict');
const { test } = require('node:test');
const { toneWindow } = require('./tone-window.cjs');

function wave({ delay = 0, duration = 2, frequency = 440, bleed = 0 } = {}) {
  const sampleRate = 48000, frames = Math.round(duration * sampleRate);
  const wav = Buffer.alloc(44 + frames * 2);
  for (let i = Math.round(delay * sampleRate); i < frames; i++) {
    const time = (i / sampleRate - delay) * 2 * Math.PI;
    wav.writeInt16LE(Math.round(16000 * (Math.sin(time * frequency) + bleed * Math.sin(time * 880))), 44 + i * 2);
  }
  return wav;
}

test('analysis follows bounded startup silence without changing spectral thresholds', async () => {
  const { tonePower } = await import('../../browser-protocol/scenarios/tones.mjs');
  for (const delay of [0, 0.341333, 0.8]) {
    const wav = wave({ delay }), { first, count } = toneWindow(wav, 48000);
    assert.ok(first >= (delay + 0.099) * 48000);
    const power = frequency => tonePower(wav, 48000, frequency, first, count);
    assert.ok(power(440) > 0.001);
    assert.ok(power(880) < power(440) * 0.01);
  }
  for (const input of [{ frequency: 660 }, { bleed: 0.2 }]) {
    const wav = wave(input), { first, count } = toneWindow(wav, 48000);
    const power = frequency => tonePower(wav, 48000, frequency, first, count);
    assert.ok(!(power(440) > 0.001 && power(880) < power(440) * 0.01), 'wrong source and bleed remain detectable');
  }
});

test('silence, excessive startup delay and truncated steady audio fail', () => {
  assert.throws(() => toneWindow(Buffer.alloc(44 + 96000), 48000), /within one second/);
  assert.throws(() => toneWindow(wave({ delay: 1.1 }), 48000), /within one second/);
  assert.throws(() => toneWindow(wave({ delay: 0.2, duration: 0.4 }), 48000), /complete steady-source/);
});
