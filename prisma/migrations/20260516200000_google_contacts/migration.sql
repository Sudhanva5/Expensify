-- CreateTable
CREATE TABLE "GoogleContact" (
    "id" TEXT NOT NULL,
    "resourceName" TEXT NOT NULL,
    "displayName" TEXT,
    "givenName" TEXT,
    "familyName" TEXT,
    "phoneDigits" TEXT[],
    "phonesRaw" TEXT[],
    "emails" TEXT[],
    "photoUrl" TEXT,
    "syncedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "GoogleContact_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "GoogleContact_resourceName_key" ON "GoogleContact"("resourceName");

-- CreateIndex
CREATE INDEX "GoogleContact_syncedAt_idx" ON "GoogleContact"("syncedAt");
