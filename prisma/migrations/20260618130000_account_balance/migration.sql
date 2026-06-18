-- CreateTable
CREATE TABLE "AccountBalance" (
    "id" TEXT NOT NULL,
    "instrument" TEXT NOT NULL,
    "balanceInrMinor" BIGINT NOT NULL,
    "asOf" TIMESTAMP(3) NOT NULL,
    "source" TEXT NOT NULL DEFAULT 'hdfc_balance_email',
    "gmailMessageId" TEXT,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "AccountBalance_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "AccountBalance_instrument_key" ON "AccountBalance"("instrument");

-- CreateIndex
CREATE UNIQUE INDEX "AccountBalance_gmailMessageId_key" ON "AccountBalance"("gmailMessageId");

-- CreateIndex
CREATE INDEX "AccountBalance_asOf_idx" ON "AccountBalance"("asOf");
