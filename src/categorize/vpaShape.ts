// Classify a UPI VPA as merchant / personal / unknown by structural pattern.
// Merchant VPAs typically use opaque ids (q-prefix on PhonePe Business, etc).
// Personal VPAs typically have a name-shaped local part on a personal handle.

import type { VpaShape } from './types.js';

const MERCHANT_VPA = /^q\d+@(ybl|ibl|paytm|axisb)$/i;

const PERSONAL_HANDLES = new Set([
  'oksbi',
  'okaxis',
  'okhdfcbank',
  'okicici',
  'apl',
]);

export function classifyVpa(vpa: string): VpaShape {
  const trimmed = vpa.trim().toLowerCase();
  if (!trimmed.includes('@')) return 'unknown';

  if (MERCHANT_VPA.test(trimmed)) return 'merchant';

  const atIdx = trimmed.lastIndexOf('@');
  const local = trimmed.slice(0, atIdx);
  const handle = trimmed.slice(atIdx + 1);
  if (!local || !handle) return 'unknown';

  if (PERSONAL_HANDLES.has(handle)) {
    // Local part starts with a letter and contains letters → looks personal.
    // Pure-numeric locals (like 9876543210@paytm) are often merchant phones; skip.
    if (/^[a-z]/.test(local) && /[a-z]/.test(local)) return 'personal';
  }

  return 'unknown';
}
