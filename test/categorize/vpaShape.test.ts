import { describe, it, expect } from 'vitest';
import { classifyVpa } from '../../src/categorize/vpaShape.js';

describe('classifyVpa', () => {
  it('classifies SNEHA personal VPA as personal', () => {
    expect(classifyVpa('s.neha2003rajesh-1@okaxis')).toBe('personal');
  });

  it('classifies q-prefixed @ybl as merchant', () => {
    expect(classifyVpa('q201985284@ybl')).toBe('merchant');
  });

  it('classifies a name on @oksbi as personal', () => {
    expect(classifyVpa('anand.kumar@oksbi')).toBe('personal');
  });

  it('returns unknown for unfamiliar handles', () => {
    expect(classifyVpa('something@randomhandle')).toBe('unknown');
  });

  it('classifies phone-shaped local on a personal handle as personal', () => {
    // Updated from the older "unknown" expectation. Phone numbers on
    // consumer handles (e.g. `9876543210@paytm`, `9876543210@ybl`) are
    // overwhelmingly personal accounts — the classifier was expanded to
    // recognize this so we auto-tag P2P transfers correctly.
    expect(classifyVpa('9876543210@paytm')).toBe('personal');
    expect(classifyVpa('9876543210@ybl')).toBe('personal');
  });

  it('returns unknown for input without @', () => {
    expect(classifyVpa('not-a-vpa')).toBe('unknown');
  });
});
