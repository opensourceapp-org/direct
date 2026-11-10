package app.direct.messaging.platform

import app.direct.core.signaling.BootstrapUrl
import app.direct.core.signaling.WebSocketConnection
import app.direct.core.signaling.WebSocketEvents
import app.direct.core.signaling.WebSocketFactory
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject

/** ws:// uses a WebSocket. wss:// uses HTTPS POST /signal so the hosted hub can run without a sticky socket. */
class OkHttpWebSocketFactory(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(25, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .build(),
) : WebSocketFactory {
    override fun open(url: String, events: WebSocketEvents): WebSocketConnection {
        if (BootstrapUrl.usesHttpSignal(url)) return HttpSignalConnection(BootstrapUrl.httpSignalUrl(url), events, client)
        val closed = AtomicBoolean(false)
        fun finish(error: String?) {
            if (closed.compareAndSet(false, true)) events.onClosed(error)
        }
        val socket = client.newWebSocket(
            Request.Builder().url(url).build(),
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) = events.onOpen()
                override fun onMessage(webSocket: WebSocket, text: String) = events.onMessage(text)
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    webSocket.close(1000, null)
                    finish(reason.ifEmpty { null })
                }
                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = finish(reason.ifEmpty { null })
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
                    finish(t.message ?: t.javaClass.simpleName)
            },
        )
        return object : WebSocketConnection {
            override fun send(text: String): Boolean = socket.send(text)
            override fun close() {
                closed.set(true)
                socket.close(1000, null)
            }
        }
    }
}

private class HttpSignalConnection(
    private val endpoint: String,
    private val events: WebSocketEvents,
    private val client: OkHttpClient,
) : WebSocketConnection {
    private val closed = AtomicBoolean(false)
    private val session = AtomicReference<String?>(null)
    private val outgoing = ConcurrentLinkedQueue<String>()
    private val wake = Semaphore(0)

    init {
        client.dispatcher.executorService.execute {
            events.onOpen()
            loop@ while (!closed.get()) {
                val frames = drain()
                val waitMs = if (frames.isEmpty()) 2_000 else 0
                try {
                    val body = JSONObject()
                        .put("waitMs", waitMs)
                        .put("frames", JSONArray().also { array ->
                            for (frame in frames) array.put(JSONObject(frame))
                        })
                    session.get()?.let { body.put("session", it) }
                    val request = Request.Builder()
                        .url(endpoint)
                        .post(body.toString().toRequestBody(JSON))
                        .apply { session.get()?.let { header("X-Direct-Session", it) } }
                        .build()
                    client.newCall(request).execute().use { response ->
                        if (!response.isSuccessful) {
                            finish(response.message.ifEmpty { "The bootstrap closed the connection." })
                            return@execute
                        }
                        val parsed = JSONObject(response.body?.string().orEmpty())
                        session.set(parsed.optString("session").ifEmpty { session.get() })
                        val inbound = parsed.optJSONArray("frames") ?: JSONArray()
                        for (i in 0 until inbound.length()) {
                            events.onMessage(inbound.getJSONObject(i).toString())
                        }
                    }
                    if (closed.get()) break@loop
                } catch (error: Exception) {
                    finish(error.message ?: error.javaClass.simpleName)
                    break@loop
                }
            }
        }
    }

    override fun send(text: String): Boolean {
        if (closed.get()) return false
        outgoing.add(text)
        wake.release()
        return true
    }

    override fun close() {
        closed.set(true)
        wake.release()
    }

    private fun drain(): List<String> {
        if (outgoing.isEmpty()) wake.tryAcquire(50, TimeUnit.MILLISECONDS)
        val frames = mutableListOf<String>()
        while (true) {
            val next = outgoing.poll() ?: break
            frames.add(next)
        }
        return frames
    }

    private fun finish(error: String?) {
        if (closed.compareAndSet(false, true)) {
            wake.release()
            events.onClosed(error)
        }
    }

    companion object {
        private val JSON = "application/json; charset=utf-8".toMediaType()
    }
}
