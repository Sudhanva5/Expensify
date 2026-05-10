-- CreateEnum
CREATE TYPE "Direction" AS ENUM ('in', 'out');

-- CreateEnum
CREATE TYPE "LocationStatus" AS ENUM ('awaiting', 'fulfilled', 'missed', 'not_applicable');

-- CreateEnum
CREATE TYPE "TxStatus" AS ENUM ('awaiting_location', 'pending_review', 'resolved');

-- CreateTable
CREATE TABLE "Transaction" (
    "id" TEXT NOT NULL,
    "amountMinor" BIGINT NOT NULL,
    "currency" TEXT NOT NULL DEFAULT 'INR',
    "amountInrMinor" BIGINT,
    "bankConvertedRate" DECIMAL(12,6),
    "marketRate" DECIMAL(12,6),
    "fxMarkupPct" DECIMAL(6,3),
    "merchantRaw" TEXT NOT NULL,
    "merchantNormalized" TEXT NOT NULL,
    "vpa" TEXT,
    "occurredAt" TIMESTAMP(3) NOT NULL,
    "direction" "Direction" NOT NULL,
    "instrument" TEXT NOT NULL,
    "gmailMessageId" TEXT NOT NULL,
    "emailTemplate" TEXT NOT NULL,
    "parserVersion" TEXT NOT NULL,
    "rawSubject" TEXT NOT NULL,
    "rawSnippet" TEXT NOT NULL,
    "locationLat" DECIMAL(10,7),
    "locationLng" DECIMAL(10,7),
    "locationStatus" "LocationStatus" NOT NULL DEFAULT 'awaiting',
    "categoryId" TEXT,
    "confidence" DECIMAL(4,3),
    "signalSource" TEXT,
    "matchedRuleId" TEXT,
    "status" "TxStatus" NOT NULL DEFAULT 'awaiting_location',
    "autoFinalized" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Transaction_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Category" (
    "id" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "parentId" TEXT,

    CONSTRAINT "Category_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Tag" (
    "id" TEXT NOT NULL,
    "name" TEXT NOT NULL,

    CONSTRAINT "Tag_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "TransactionTag" (
    "transactionId" TEXT NOT NULL,
    "tagId" TEXT NOT NULL,

    CONSTRAINT "TransactionTag_pkey" PRIMARY KEY ("transactionId","tagId")
);

-- CreateTable
CREATE TABLE "MerchantAlias" (
    "id" TEXT NOT NULL,
    "rawPattern" TEXT NOT NULL,
    "canonical" TEXT NOT NULL,
    "categoryId" TEXT,
    "matchType" TEXT NOT NULL DEFAULT 'exact',
    "notes" TEXT,

    CONSTRAINT "MerchantAlias_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "MerchantPattern" (
    "id" TEXT NOT NULL,
    "merchantNormalized" TEXT NOT NULL,
    "categoryId" TEXT NOT NULL,
    "hitCount" INTEGER NOT NULL DEFAULT 1,
    "autoTagActive" BOOLEAN NOT NULL DEFAULT false,
    "firstSeenAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "lastConfirmedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "MerchantPattern_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "UserRule" (
    "id" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "priority" INTEGER NOT NULL DEFAULT 100,
    "enabled" BOOLEAN NOT NULL DEFAULT true,
    "conditions" JSONB NOT NULL,
    "categoryId" TEXT NOT NULL,
    "defaultConfidence" DECIMAL(4,3) NOT NULL DEFAULT 0.6,
    "hitCount" INTEGER NOT NULL DEFAULT 0,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "UserRule_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Budget" (
    "id" TEXT NOT NULL,
    "categoryId" TEXT NOT NULL,
    "monthlyLimitInr" BIGINT NOT NULL,
    "alertThresholds" DECIMAL(4,3)[],
    "enabled" BOOLEAN NOT NULL DEFAULT true,

    CONSTRAINT "Budget_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "BudgetAlertFired" (
    "id" TEXT NOT NULL,
    "budgetId" TEXT NOT NULL,
    "yearMonth" TEXT NOT NULL,
    "threshold" DECIMAL(4,3) NOT NULL,
    "firedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "BudgetAlertFired_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Goal" (
    "id" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "targetAmountInr" BIGINT NOT NULL,
    "deadline" TIMESTAMP(3) NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Goal_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "GmailOauth" (
    "id" TEXT NOT NULL,
    "refreshToken" TEXT NOT NULL,
    "watchExpiresAt" TIMESTAMP(3),
    "lastHistoryId" TEXT,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "GmailOauth_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "DeviceToken" (
    "id" TEXT NOT NULL,
    "apnsToken" TEXT NOT NULL,
    "lastSeen" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "DeviceToken_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "FxRate" (
    "id" TEXT NOT NULL,
    "date" DATE NOT NULL,
    "currency" TEXT NOT NULL,
    "rateInr" DECIMAL(12,6) NOT NULL,

    CONSTRAINT "FxRate_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ParserHealth" (
    "id" TEXT NOT NULL,
    "template" TEXT NOT NULL,
    "lastParsedAt" TIMESTAMP(3) NOT NULL,
    "lastParserVersion" TEXT NOT NULL,

    CONSTRAINT "ParserHealth_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "EmailMessage" (
    "id" TEXT NOT NULL,
    "gmailMessageId" TEXT NOT NULL,
    "kind" TEXT NOT NULL,
    "parsedAt" TIMESTAMP(3),
    "parserVersion" TEXT,
    "rawSubject" TEXT NOT NULL,
    "rawSnippet" TEXT NOT NULL,
    "rawHeaders" JSONB,
    "parseError" TEXT,
    "receivedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "EmailMessage_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "Transaction_gmailMessageId_key" ON "Transaction"("gmailMessageId");

-- CreateIndex
CREATE INDEX "Transaction_occurredAt_idx" ON "Transaction"("occurredAt");

-- CreateIndex
CREATE INDEX "Transaction_categoryId_occurredAt_idx" ON "Transaction"("categoryId", "occurredAt");

-- CreateIndex
CREATE INDEX "Transaction_merchantNormalized_idx" ON "Transaction"("merchantNormalized");

-- CreateIndex
CREATE INDEX "Transaction_status_idx" ON "Transaction"("status");

-- CreateIndex
CREATE UNIQUE INDEX "Category_name_key" ON "Category"("name");

-- CreateIndex
CREATE UNIQUE INDEX "Tag_name_key" ON "Tag"("name");

-- CreateIndex
CREATE UNIQUE INDEX "MerchantAlias_rawPattern_key" ON "MerchantAlias"("rawPattern");

-- CreateIndex
CREATE UNIQUE INDEX "MerchantPattern_merchantNormalized_key" ON "MerchantPattern"("merchantNormalized");

-- CreateIndex
CREATE UNIQUE INDEX "Budget_categoryId_key" ON "Budget"("categoryId");

-- CreateIndex
CREATE UNIQUE INDEX "BudgetAlertFired_budgetId_yearMonth_threshold_key" ON "BudgetAlertFired"("budgetId", "yearMonth", "threshold");

-- CreateIndex
CREATE UNIQUE INDEX "DeviceToken_apnsToken_key" ON "DeviceToken"("apnsToken");

-- CreateIndex
CREATE UNIQUE INDEX "FxRate_date_currency_key" ON "FxRate"("date", "currency");

-- CreateIndex
CREATE UNIQUE INDEX "ParserHealth_template_key" ON "ParserHealth"("template");

-- CreateIndex
CREATE UNIQUE INDEX "EmailMessage_gmailMessageId_key" ON "EmailMessage"("gmailMessageId");

-- AddForeignKey
ALTER TABLE "Transaction" ADD CONSTRAINT "Transaction_categoryId_fkey" FOREIGN KEY ("categoryId") REFERENCES "Category"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Category" ADD CONSTRAINT "Category_parentId_fkey" FOREIGN KEY ("parentId") REFERENCES "Category"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "TransactionTag" ADD CONSTRAINT "TransactionTag_transactionId_fkey" FOREIGN KEY ("transactionId") REFERENCES "Transaction"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "TransactionTag" ADD CONSTRAINT "TransactionTag_tagId_fkey" FOREIGN KEY ("tagId") REFERENCES "Tag"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MerchantAlias" ADD CONSTRAINT "MerchantAlias_categoryId_fkey" FOREIGN KEY ("categoryId") REFERENCES "Category"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MerchantPattern" ADD CONSTRAINT "MerchantPattern_categoryId_fkey" FOREIGN KEY ("categoryId") REFERENCES "Category"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "UserRule" ADD CONSTRAINT "UserRule_categoryId_fkey" FOREIGN KEY ("categoryId") REFERENCES "Category"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Budget" ADD CONSTRAINT "Budget_categoryId_fkey" FOREIGN KEY ("categoryId") REFERENCES "Category"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "BudgetAlertFired" ADD CONSTRAINT "BudgetAlertFired_budgetId_fkey" FOREIGN KEY ("budgetId") REFERENCES "Budget"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
