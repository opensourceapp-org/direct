package app.direct.core

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

object Encoding {
    private const val CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    private val random = SecureRandom()

    fun utf8(value: String): ByteArray = value.toByteArray(Charsets.UTF_8)

    fun text(bytes: ByteArray): String = String(bytes, Charsets.UTF_8)

    fun base64Url(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    fun fromBase64Url(value: String): ByteArray = Base64.getUrlDecoder().decode(value.trimEnd('='))

    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    fun fromHex(value: String): ByteArray {
        require(value.length % 2 == 0) { "Hex string has an odd length." }
        return ByteArray(value.length / 2) { value.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }

    fun sha256(vararg parts: ByteArray): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        for (part in parts) digest.update(part)
        return digest.digest()
    }

    fun crockford(bytes: ByteArray): String {
        val out = StringBuilder()
        var bits = 0
        var value = 0
        for (byte in bytes) {
            value = (value shl 8) or (byte.toInt() and 0xff)
            bits += 8
            while (bits >= 5) {
                bits -= 5
                out.append(CROCKFORD[(value ushr bits) and 31])
            }
            value = value and ((1 shl bits) - 1)
        }
        if (bits > 0) out.append(CROCKFORD[(value shl (5 - bits)) and 31])
        return out.toString()
    }

    fun randomBytes(length: Int): ByteArray = ByteArray(length).also(random::nextBytes)

    fun newId(prefix: String): String = "${prefix}_${hex(randomBytes(16))}"

    fun newDeviceId(): String = "dev_${crockford(randomBytes(10))}"

    fun constantTimeEquals(left: ByteArray, right: ByteArray): Boolean = MessageDigest.isEqual(left, right)
}
