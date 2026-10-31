package app.direct.core.store

import app.direct.core.Encoding
import app.direct.core.crypto.IdentityKeys
import app.direct.core.crypto.Mnemonic

/**
 * Platform secret storage. Android backs it with an Android Keystore AES key that never
 * leaves secure hardware; iOS backs it with the Keychain and, where present, a Secure Enclave
 * key that wraps each value. Implementations must not fall back to plain preferences.
 */
interface SecretStore {
    fun read(name: String): ByteArray?
    fun write(name: String, value: ByteArray)
    fun delete(name: String)
}

class MemorySecretStore : SecretStore {
    private val values = mutableMapOf<String, ByteArray>()

    @Synchronized
    override fun read(name: String): ByteArray? = values[name]?.copyOf()

    @Synchronized
    override fun write(name: String, value: ByteArray) {
        values[name] = value.copyOf()
    }

    @Synchronized
    override fun delete(name: String) {
        values.remove(name)?.fill(0)
    }

    @Synchronized
    fun names(): Set<String> = values.keys.toSet()
}

/** Identity seed and storage key, both held only in the platform secret store. */
class IdentityVault(private val secrets: SecretStore) {
    fun load(): IdentityKeys? = secrets.read(SEED)?.let { seed ->
        try {
            IdentityKeys.fromSeed(seed)
        } finally {
            seed.fill(0)
        }
    }

    fun create(): Pair<IdentityKeys, String> {
        val keys = IdentityKeys.generate()
        secrets.write(SEED, keys.seed)
        return keys to Mnemonic.fromSeed(keys.seed)
    }

    fun restore(phrase: String): IdentityKeys {
        val seed = Mnemonic.toSeed(phrase)
        try {
            secrets.write(SEED, seed)
            return IdentityKeys.fromSeed(seed)
        } finally {
            seed.fill(0)
        }
    }

    fun recoveryPhrase(): String? = load()?.let { Mnemonic.fromSeed(it.seed) }

    /** 32-byte key for the encrypted local store, created on first use. */
    fun storageKey(): ByteArray = secrets.read(STORE_KEY) ?: Encoding.randomBytes(32).also { secrets.write(STORE_KEY, it) }

    fun erase() {
        secrets.delete(SEED)
        secrets.delete(STORE_KEY)
    }

    companion object {
        const val SEED = "identity.seed"
        const val STORE_KEY = "store.key"
    }
}
