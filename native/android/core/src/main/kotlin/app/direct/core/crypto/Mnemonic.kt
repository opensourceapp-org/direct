package app.direct.core.crypto

import app.direct.core.Encoding

/** BIP-39 English, 24 words for the 32-byte identity seed. */
object Mnemonic {
    private val words: List<String> by lazy {
        val stream = Mnemonic::class.java.getResourceAsStream("/direct/bip39-english.txt")
            ?: error("BIP-39 wordlist is missing from the build.")
        stream.bufferedReader().readLines().filter { it.isNotBlank() }.also { check(it.size == 2048) }
    }
    private val index: Map<String, Int> by lazy { words.withIndex().associate { it.value to it.index } }

    fun fromSeed(seed: ByteArray): String {
        if (seed.size != 32) throw IdentityException("Identity seed must be 32 bytes.")
        val checksum = Encoding.sha256(seed)[0]
        val bits = BooleanArray(264)
        for (i in 0 until 256) bits[i] = (seed[i / 8].toInt() shr (7 - i % 8)) and 1 == 1
        for (i in 0 until 8) bits[256 + i] = (checksum.toInt() shr (7 - i)) and 1 == 1
        return (0 until 24).joinToString(" ") { group ->
            var value = 0
            for (bit in 0 until 11) value = (value shl 1) or if (bits[group * 11 + bit]) 1 else 0
            words[value]
        }
    }

    fun toSeed(phrase: String): ByteArray {
        val parts = phrase.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (parts.size != 24) throw IdentityException("Recovery phrase is not valid.")
        val bits = BooleanArray(264)
        parts.forEachIndexed { group, word ->
            val value = index[word] ?: throw IdentityException("Recovery phrase is not valid.")
            for (bit in 0 until 11) bits[group * 11 + bit] = (value shr (10 - bit)) and 1 == 1
        }
        val seed = ByteArray(32)
        for (i in 0 until 256) if (bits[i]) seed[i / 8] = (seed[i / 8].toInt() or (1 shl (7 - i % 8))).toByte()
        var checksum = 0
        for (i in 0 until 8) checksum = (checksum shl 1) or if (bits[256 + i]) 1 else 0
        if (checksum != (Encoding.sha256(seed)[0].toInt() and 0xff)) throw IdentityException("Recovery phrase is not valid.")
        return seed
    }
}
