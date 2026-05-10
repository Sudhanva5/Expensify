// Single Prisma client instance — import this everywhere instead of
// creating new clients (prevents connection pool exhaustion).

import { PrismaClient } from '@prisma/client';

declare global {
  // eslint-disable-next-line no-var
  var __prismaClient: PrismaClient | undefined;
}

export const prisma: PrismaClient =
  globalThis.__prismaClient ??
  new PrismaClient({
    log: process.env['NODE_ENV'] === 'production' ? ['error'] : ['warn', 'error'],
  });

if (process.env['NODE_ENV'] !== 'production') {
  globalThis.__prismaClient = prisma;
}
