package app.direct.messaging

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * Not compiled into the Capacitor shell yet. WorkManager is not a dependency of
 * the installable project. The installed app retries the queue while it is open.
 */
class DeliveryWorker(
  context: Context,
  params: WorkerParameters,
) : CoroutineWorker(context, params) {
  override suspend fun doWork(): Result {
    val flushed = DirectBackgroundBridge.flush(applicationContext)
    return if (flushed) Result.success() else Result.retry()
  }

  companion object {
    private const val NAME = "direct-delivery-flush"

    fun schedule(context: Context) {
      val request = PeriodicWorkRequestBuilder<DeliveryWorker>(15, TimeUnit.MINUTES).build()
      WorkManager.getInstance(context).enqueueUniquePeriodicWork(
        NAME,
        ExistingPeriodicWorkPolicy.UPDATE,
        request,
      )
    }
  }
}

class BootReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent?) {
    if (intent?.action == Intent.ACTION_BOOT_COMPLETED) {
      DeliveryWorker.schedule(context)
    }
  }
}

object DirectBackgroundBridge {
  fun flush(context: Context): Boolean {
    return context.applicationContext != null
  }
}
