-- CreateTable
CREATE TABLE "VpaPattern" (
    "id" TEXT NOT NULL,
    "vpa" TEXT NOT NULL,
    "categoryId" TEXT NOT NULL,
    "hitCount" INTEGER NOT NULL DEFAULT 1,
    "firstSeenAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "lastConfirmedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "VpaPattern_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "VpaPattern_vpa_key" ON "VpaPattern"("vpa");

-- AddForeignKey
ALTER TABLE "VpaPattern" ADD CONSTRAINT "VpaPattern_categoryId_fkey" FOREIGN KEY ("categoryId") REFERENCES "Category"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
