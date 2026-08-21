-- AlterTable
ALTER TABLE "Transaction" ADD COLUMN     "vpaGateway" TEXT,
ADD COLUMN     "vpaMerchant" TEXT;

-- CreateIndex
CREATE INDEX "Transaction_vpaGateway_idx" ON "Transaction"("vpaGateway");
