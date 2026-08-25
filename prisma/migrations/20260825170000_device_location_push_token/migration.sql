-- AlterTable
ALTER TABLE "DeviceToken" ADD COLUMN     "locationPushToken" TEXT;

-- CreateIndex
CREATE UNIQUE INDEX "DeviceToken_locationPushToken_key" ON "DeviceToken"("locationPushToken");
