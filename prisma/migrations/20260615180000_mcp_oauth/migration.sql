-- CreateTable
CREATE TABLE "McpOAuthClient" (
    "id" TEXT NOT NULL,
    "clientName" TEXT,
    "redirectUris" TEXT[],
    "grantTypes" TEXT[],
    "responseTypes" TEXT[],
    "tokenEndpointAuthMethod" TEXT NOT NULL DEFAULT 'none',
    "scope" TEXT,
    "metadata" JSONB NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "lastUsedAt" TIMESTAMP(3),

    CONSTRAINT "McpOAuthClient_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "McpOAuthClient_createdAt_idx" ON "McpOAuthClient"("createdAt");

-- CreateTable
CREATE TABLE "McpAuthCode" (
    "code" TEXT NOT NULL,
    "clientId" TEXT NOT NULL,
    "redirectUri" TEXT NOT NULL,
    "codeChallenge" TEXT NOT NULL,
    "codeChallengeMethod" TEXT NOT NULL DEFAULT 'S256',
    "scope" TEXT,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "consumed" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "McpAuthCode_pkey" PRIMARY KEY ("code")
);

-- CreateIndex
CREATE INDEX "McpAuthCode_clientId_idx" ON "McpAuthCode"("clientId");

-- CreateIndex
CREATE INDEX "McpAuthCode_expiresAt_idx" ON "McpAuthCode"("expiresAt");

-- AddForeignKey
ALTER TABLE "McpAuthCode" ADD CONSTRAINT "McpAuthCode_clientId_fkey" FOREIGN KEY ("clientId") REFERENCES "McpOAuthClient"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- CreateTable
CREATE TABLE "McpAccessToken" (
    "id" TEXT NOT NULL,
    "tokenHash" TEXT NOT NULL,
    "clientId" TEXT NOT NULL,
    "scope" TEXT,
    "label" TEXT,
    "issuedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expiresAt" TIMESTAMP(3),
    "lastUsedAt" TIMESTAMP(3),
    "revokedAt" TIMESTAMP(3),

    CONSTRAINT "McpAccessToken_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "McpAccessToken_tokenHash_key" ON "McpAccessToken"("tokenHash");

-- CreateIndex
CREATE INDEX "McpAccessToken_clientId_idx" ON "McpAccessToken"("clientId");

-- CreateIndex
CREATE INDEX "McpAccessToken_revokedAt_idx" ON "McpAccessToken"("revokedAt");

-- AddForeignKey
ALTER TABLE "McpAccessToken" ADD CONSTRAINT "McpAccessToken_clientId_fkey" FOREIGN KEY ("clientId") REFERENCES "McpOAuthClient"("id") ON DELETE CASCADE ON UPDATE CASCADE;
