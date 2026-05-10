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

  it('returns unknown for purely numeric local on @paytm', () => {
    expect(classifyVpa('9876543210@paytm')).toBe('unknown');
  });

  it('returns unknown for input without @', () => {
    expect(classifyVpa('not-a-vpa')).toBe('unknown');
  });
});
