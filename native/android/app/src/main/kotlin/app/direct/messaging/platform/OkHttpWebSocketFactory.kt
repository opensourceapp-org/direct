package app.direct.messaging.platform

import app.direct.core.signaling.WebSocketConnection
import app.direct.core.signaling.WebSocketEvents
import app.direct.core.signaling.WebSocketFactory
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/** ws:// and wss:// to the bootstrap. Pings keep NATs and the server's idle timers open. */
class OkHttpWebSocketFactory(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .build(),
) : WebSocketFactory {
    override fun open(url: String, events: WebSocketEvents): WebSocketConnection {
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
