package app.direct.core.signaling

/** Mirrors contracts/bootstrap-url.json and packages/protocol/src/bootstrapUrl.ts. */
object BootstrapUrl {
    const val DEFAULT_PORT = 8787

    /** Public hosted bootstrap. Phones save this on first start unless a different address is already stored. */
    const val DEFAULT = "wss://direct-signaling.apps.grok.bot"

    /** Bumped when the public hosted bootstrap became the default. */
    const val HOSTED_DEFAULT_VERSION = 1

    fun storedOrDefault(stored: String?): String {
        val value = stored?.trim().orEmpty()
        return value.ifEmpty { DEFAULT }
    }

    data class Chosen(val url: String, val version: Int)

    fun isLegacyLanDefault(input: String): Boolean {
        val result = normalize(input)
        if (result !is Result.Ok) return false
        val url = result.url
        if (!url.startsWith("ws://") || '/' in url.substring("ws://".length) || !url.endsWith(":$DEFAULT_PORT")) return false
        val host = url.removePrefix("ws://").removeSuffix(":$DEFAULT_PORT")
        if (host.startsWith("[")) return false
        return privateIpv4(host)
    }

    fun applyHostedDefault(stored: String?, version: Int): Chosen {
        if (version >= HOSTED_DEFAULT_VERSION) return Chosen(storedOrDefault(stored), version)
        val current = stored?.trim().orEmpty()
        val url = if (current.isEmpty() || isLegacyLanDefault(current)) DEFAULT else current
        return Chosen(url, HOSTED_DEFAULT_VERSION)
    }

    private fun privateIpv4(host: String): Boolean {
        val parts = host.split('.')
        if (parts.size != 4) return false
        val octets = parts.map { it.toIntOrNull() ?: return false }
        if (octets.any { it !in 0..255 }) return false
        val a = octets[0]
        val b = octets[1]
        return a == 10 || a == 192 && b == 168 || a == 172 && b in 16..31 || a == 169 && b == 254
    }

    enum class Error(val message: String) {
        EMPTY("Enter the bootstrap address, such as ws://192.168.1.20:8787."),
        SCHEME("Use a ws:// or wss:// address."),
        HOST("The bootstrap address needs a host name or IP address, with no spaces."),
        PORT("The port must be a number from 1 to 65535."),
        USERINFO("Remove the user name and password from the address."),
        QUERY("Remove the ? or # part from the address."),
        LOOPBACK("localhost on a phone is the phone itself. Use the computer's network address, the same one on both phones."),
        ;

        val code: String get() = name.lowercase()
    }

    sealed interface Result {
        data class Ok(val url: String) : Result
        data class Invalid(val error: Error) : Result
    }

    private val schemePattern = Regex("^([A-Za-z][A-Za-z0-9+.-]*)://(.*)$")
    private val schemes = mapOf("ws" to "ws", "wss" to "wss", "http" to "ws", "https" to "wss")

    fun normalize(input: String): Result {
        val value = input.trim()
        if (value.isEmpty()) return Result.Invalid(Error.EMPTY)
        val match = schemePattern.matchEntire(value)
        val scheme = if (match != null) schemes[match.groupValues[1].lowercase()] else "ws"
        if (scheme == null) return Result.Invalid(Error.SCHEME)
        val rest = match?.groupValues?.get(2) ?: value
        if (rest.any { it.isWhitespace() }) return Result.Invalid(Error.HOST)
        if ('?' in rest || '#' in rest) return Result.Invalid(Error.QUERY)
        val slash = rest.indexOf('/')
        val authority = if (slash == -1) rest else rest.substring(0, slash)
        val path = (if (slash == -1) "" else rest.substring(slash)).trimEnd('/')
        if ('@' in authority) return Result.Invalid(Error.USERINFO)

        val host: String
        var port: String? = null
        val bracketed = authority.startsWith("[")
        if (bracketed) {
            val close = authority.indexOf(']')
            if (close == -1) return Result.Invalid(Error.HOST)
            host = authority.substring(1, close).lowercase()
            val after = authority.substring(close + 1)
            if (after.startsWith(":")) port = after.substring(1) else if (after.isNotEmpty()) return Result.Invalid(Error.HOST)
            if (!Regex("^[0-9a-f:.]+$").matches(host)) return Result.Invalid(Error.HOST)
        } else {
            val parts = authority.split(":")
            if (parts.size > 2) return Result.Invalid(Error.HOST)
            host = parts[0].lowercase()
            if (parts.size == 2) port = parts[1]
            if (!Regex("^[a-z0-9.-]+$").matches(host)) return Result.Invalid(Error.HOST)
        }

        val portNumber: Int? = when {
            port != null -> {
                if (!Regex("^[0-9]{1,5}$").matches(port)) return Result.Invalid(Error.PORT)
                port.toInt().takeIf { it in 1..65535 } ?: return Result.Invalid(Error.PORT)
            }
            scheme == "ws" -> DEFAULT_PORT
            else -> null
        }

        val loopback = host == "localhost" || host.endsWith(".localhost") || host.startsWith("127.") || host == "::1" || host == "0.0.0.0"
        if (loopback) return Result.Invalid(Error.LOOPBACK)

        val shownHost = if (bracketed) "[$host]" else host
        return Result.Ok("$scheme://$shownHost${portNumber?.let { ":$it" } ?: ""}$path")
    }
}
