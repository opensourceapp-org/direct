package app.direct.core

import app.direct.core.crypto.Mnemonic
import app.direct.core.crypto.SealException
import app.direct.core.delivery.MessageState
import app.direct.core.store.ContactRecord
import app.direct.core.store.Direction
import app.direct.core.store.IdentityVault
import app.direct.core.store.LocalStore
import app.direct.core.store.MemorySecretStore
import app.direct.core.store.MessageRecord
import app.direct.core.store.QueueItem
import app.direct.core.store.QueueKind
import app.direct.core.store.SecretStore
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StorageTest {
    private val dir = Files.createTempDirectory("direct-store").toFile()

    @Test
    fun `the identity seed lives only in the secret store and survives a restart`() {
        val secrets = MemorySecretStore()
        val (keys, phrase) = IdentityVault(secrets).create()
        assertEquals(setOf(IdentityVault.SEED), secrets.names())
        val reloaded = assertNotNull(IdentityVault(secrets).load())
        assertEquals(keys.directId, reloaded.directId)
        assertEquals(phrase, IdentityVault(secrets).recoveryPhrase())

        val elsewhere = MemorySecretStore()
        assertEquals(keys.directId, IdentityVault(elsewhere).restore(phrase).directId)
        assertContentEquals(Mnemonic.toSeed(phrase), elsewhere.read(IdentityVault.SEED))
    }

    @Test
    fun `the storage key is created once and kept in the secret store`() {
        val secrets = MemorySecretStore()
        val first = IdentityVault(secrets).storageKey()
        assertContentEquals(first, IdentityVault(secrets).storageKey())
        assertEquals(32, first.size)
        IdentityVault(secrets).erase()
        assertNull(secrets.read(IdentityVault.STORE_KEY))
    }

    @Test
    fun `a failing platform store is surfaced, never replaced with plain storage`() {
        val broken = object : SecretStore {
            override fun read(name: String): ByteArray? = throw IllegalStateException("Keystore unavailable")
            override fun write(name: String, value: ByteArray) = throw IllegalStateException("Keystore unavailable")
            override fun delete(name: String) = Unit
        }
        assertFailsWith<IllegalStateException> { IdentityVault(broken).create() }
        assertFailsWith<IllegalStateException> { IdentityVault(broken).storageKey() }
    }

    @Test
    fun `the queue and messages persist encrypted and reload after a restart`() {
        val file = dir.resolve("direct.store")
        val key = Encoding.randomBytes(32)
        val store = LocalStore.open(file, key)
        store.putContact(ContactRecord("dir_ABCDEFGHJKMNPQRS", "Bo", "{}", "FP", createdAt = 1))
        store.putMessage(MessageRecord("msg_1", "dir_ABCDEFGHJKMNPQRS", Direction.OUTGOING, "meet at noon", 10, MessageState.QUEUED))
        store.putQueued(QueueItem("msg_1", "dir_ABCDEFGHJKMNPQRS", QueueKind.MESSAGE, "{sealed}", 2, 50, 999))
        store.save()

        val raw = Encoding.text(file.readBytes())
        assertFalse("meet at noon" in raw)
        assertFalse("dir_ABCDEFGHJKMNPQRS" in raw)
        assertFalse(dir.resolve("direct.store.tmp").exists())

        val reopened = LocalStore.open(file, key)
        assertEquals("meet at noon", reopened.message("msg_1")?.body)
        assertEquals(MessageState.QUEUED, reopened.message("msg_1")?.state)
        assertEquals(2, reopened.queued("msg_1")?.attempts)
        assertEquals(50, reopened.queued("msg_1")?.nextAttemptAt)
    }

    @Test
    fun `a wrong key fails loudly and leaves the file intact`() {
        val file = dir.resolve("other.store")
        val store = LocalStore.open(file, Encoding.randomBytes(32))
        store.putMessage(MessageRecord("m", "p", Direction.INCOMING, "x", 1))
        store.save()
        val before = file.readBytes()
        assertFailsWith<SealException> { LocalStore.open(file, Encoding.randomBytes(32)) }
        assertTrue(before.contentEquals(file.readBytes()))
    }
}
