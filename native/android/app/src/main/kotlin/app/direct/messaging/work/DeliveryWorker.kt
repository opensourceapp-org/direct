package app.direct.messaging.work

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import app.direct.messaging.DirectApp
import java.util.concurrent.TimeUnit

/**
 * Retries the encrypted outgoing queue while DIRECT is in the background. Android decides when
 * this runs. Receiving while the screen is off is the presence foreground service, not this worker.
 */
class DeliveryWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val node = (applicationContext as DirectApp).node
        val remaining = node.backgroundFlush(budgetMs = 25_000)
        if (remaining == 0) WorkManager.getInstance(applicationContext).cancelUniqueWork(PERIODIC)
        return if (remaining > 0 && runAttemptCount < 3) Result.retry() else Result.success()
    }

    companion object {
        private const val ONE_SHOT = "direct.delivery.now"
        private const val PERIODIC = "direct.delivery.periodic"

        fun schedule(context: Context) {
            val online = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
            val manager = WorkManager.getInstance(context)
            manager.enqueueUniqueWork(
                ONE_SHOT,
                ExistingWorkPolicy.REPLACE,
                OneTimeWorkRequestBuilder<DeliveryWorker>()
                    .setConstraints(online)
                    .setInitialDelay(30, TimeUnit.SECONDS)
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                    .build(),
            )
            manager.enqueueUniquePeriodicWork(
                PERIODIC,
                ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<DeliveryWorker>(15, TimeUnit.MINUTES).setConstraints(online).build(),
            )
        }
    }
}
