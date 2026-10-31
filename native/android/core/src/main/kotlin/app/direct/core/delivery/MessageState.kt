package app.direct.core.delivery

import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToLong

/**
 * Outgoing message lifecycle. The wire receipts keep their reference names: an `ack`
 * envelope moves a message to ACCEPTED and a `read` envelope moves it to ACKNOWLEDGED.
 *
 * QUEUED        sealed and persisted on this device, waiting for a route or for its retry time
 * SENDING       an attempt is opening the data channel and writing the envelope
 * SENT          written to the recipient's open data channel; no receipt yet
 * ACCEPTED      the recipient device verified, decrypted, and stored it, and signed an `ack`
 *               (an unknown sender's message is stored as a request, and is still ACCEPTED)
 * ACKNOWLEDGED  the recipient accepted the conversation and opened the message, and signed a `read`
 * FAILED        expired before any receipt, or the recipient is blocked; a manual retry requeues it
 */
enum class MessageState {
    QUEUED,
    SENDING,
    SENT,
    ACCEPTED,
    ACKNOWLEDGED,
    FAILED;

    /** The queue keeps the payload only while a receipt is still outstanding. */
    val awaitingReceipt: Boolean get() = this == QUEUED || this == SENDING || this == SENT
}

enum class DeliveryEvent {
    /** A flush picked the message up. */
    ATTEMPT,
    /** The envelope was written to an open data channel. */
    WRITTEN,
    /** No data channel could be opened, or the write failed. */
    UNREACHABLE,
    /** SENT for longer than the receipt timeout. The recipient deduplicates, so a resend is safe. */
    RECEIPT_TIMEOUT,
    /** A verified `ack` from the recipient. */
    DELIVERY_RECEIPT,
    /** A verified `read` from the recipient. */
    READ_RECEIPT,
    /** The envelope's expiry passed with no receipt. */
    EXPIRED,
    /** The recipient is blocked on this device. */
    REJECTED,
    /** The user asked to try a failed message again. */
    RETRY,
    /** The app restarted while an attempt was in flight. */
    RECOVERED,
}

object DeliveryStateMachine {
    /** Returns the next state, or null when the event does not apply and must be ignored. */
    fun next(state: MessageState, event: DeliveryEvent): MessageState? = when (event) {
        DeliveryEvent.ATTEMPT -> if (state == MessageState.QUEUED) MessageState.SENDING else null
        DeliveryEvent.WRITTEN -> if (state == MessageState.SENDING) MessageState.SENT else null
        DeliveryEvent.UNREACHABLE -> if (state == MessageState.SENDING) MessageState.QUEUED else null
        DeliveryEvent.RECEIPT_TIMEOUT -> if (state == MessageState.SENT) MessageState.QUEUED else null
        DeliveryEvent.DELIVERY_RECEIPT -> when (state) {
            MessageState.QUEUED, MessageState.SENDING, MessageState.SENT, MessageState.FAILED -> MessageState.ACCEPTED
            else -> null
        }
        DeliveryEvent.READ_RECEIPT -> when (state) {
            MessageState.ACKNOWLEDGED -> null
            else -> MessageState.ACKNOWLEDGED
        }
        DeliveryEvent.EXPIRED, DeliveryEvent.REJECTED -> if (state.awaitingReceipt) MessageState.FAILED else null
        DeliveryEvent.RETRY -> if (state == MessageState.FAILED) MessageState.QUEUED else null
        DeliveryEvent.RECOVERED -> if (state == MessageState.SENDING || state == MessageState.SENT) MessageState.QUEUED else null
    }
}

/** 1s, 2s, 4s, … capped at five minutes, plus up to 20% jitter. Same as packages/protocol/src/backoff.ts. */
object Backoff {
    const val BASE_MS = 1_000L
    const val CAP_MS = 5 * 60 * 1_000L

    fun delayMs(attempt: Int, random: () -> Double = Math::random): Long {
        val exponent = (attempt - 1).coerceAtLeast(0)
        val exponential = min(CAP_MS.toDouble(), BASE_MS * 2.0.pow(exponent))
        return (exponential + random() * exponential * 0.2).roundToLong()
    }
}
