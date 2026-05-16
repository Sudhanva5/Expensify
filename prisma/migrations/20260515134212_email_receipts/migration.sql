-- CreateTable
CREATE TABLE "EmailReceipt" (
    "id" TEXT NOT NULL,
    "gmailMessageId" TEXT NOT NULL,
    "source" TEXT NOT NULL,
    "subject" TEXT NOT NULL,
    "snippet" TEXT NOT NULL,
    "receivedAt" TIMESTAMP(3) NOT NULL,
    "fromAddress" TEXT,
    "amountInrMinor" BIGINT,
    "orderId" TEXT,
    "itemsJson" JSONB,
    "feesJson" JSONB,
    "metaJson" JSONB,
    "parserVersion" TEXT NOT NULL,
    "parseError" TEXT,
    "transactionId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "EmailReceipt_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "EmailReceipt_gmailMessageId_key" ON "EmailReceipt"("gmailMessageId");

-- CreateIndex
CREATE INDEX "EmailReceipt_transactionId_idx" ON "EmailReceipt"("transactionId");

-- CreateIndex
CREATE INDEX "EmailReceipt_receivedAt_idx" ON "EmailReceipt"("receivedAt");

-- CreateIndex
CREATE INDEX "EmailReceipt_source_receivedAt_idx" ON "EmailReceipt"("source", "receivedAt");

-- AddForeignKey
ALTER TABLE "EmailReceipt" ADD CONSTRAINT "EmailReceipt_transactionId_fkey" FOREIGN KEY ("transactionId") REFERENCES "Transaction"("id") ON DELETE SET NULL ON UPDATE CASCADE;
