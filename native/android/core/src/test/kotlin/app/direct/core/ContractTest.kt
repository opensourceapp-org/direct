package app.direct.core

import app.direct.core.crypto.Bundles
import app.direct.core.crypto.IdentityKeys
import app.direct.core.crypto.Mnemonic
import app.direct.core.crypto.Seal
import app.direct.core.delivery.Backoff
import app.direct.core.protocol.EnvelopeType
import app.direct.core.protocol.Envelopes
import app.direct.core.signaling.BootstrapUrl
import app.direct.core.signaling.SignalCodec
import app.direct.core.signaling.SignalFrame
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

class ContractTest {
    private val vectors = Contracts.json("vectors.json").jsonObject
    private fun JsonObject.s(name: String) = getValue(name).jsonPrimitive.content

    @Test
    fun `identity fields and bundle bytes match the TypeScript reference`() {
        for (who in listOf("ada", "bo")) {
            val vector = vectors.getValue(who).jsonObject
            val keys = IdentityKeys.fromSeed(Encoding.fromHex(vector.s("seedHex")))
            assertEquals(vector.s("signingPublic"), Encoding.base64Url(keys.signingPublic))
            assertEquals(vector.s("agreementSecret"), Encoding.base64Url(keys.agreementSecret))
            assertEquals(vector.s("agreementPublic"), Encoding.base64Url(keys.agreementPublic))
            assertEquals(vector.s("directId"), keys.directId)
            val bundle = Bundles.create(keys, vector.s("name"), vector.s("deviceId"))
            assertEquals(vector.s("did"), bundle.did)
            assertEquals(vector.s("fingerprint"), bundle.fingerprint)
            assertEquals(vector.s("bundle"), bundle.encode())
            assertEquals(vector.s("mnemonic"), Mnemonic.fromSeed(keys.seed))
            assertEquals(vector.s("seedHex"), Encoding.hex(Mnemonic.toSeed(vector.s("mnemonic"))))
            assertEquals(vector.s("directId"), Bundles.parse(vector.s("bundle")).directId)
        }
        val escaped = vectors.getValue("escapedName").jsonObject
        val ada = IdentityKeys.fromSeed(Encoding.fromHex(vectors.getValue("ada").jsonObject.s("seedHex")))
        assertEquals(escaped.s("bundle"), Bundles.create(ada, escaped.s("name"), "dev_0000000000000ADA").encode())
        assertEquals(escaped.s("name"), Bundles.parse(escaped.s("bundle")).name)
    }

    @Test
    fun `a tampered bundle is rejected`() {
        val bundle = vectors.getValue("ada").jsonObject.s("bundle")
        assertFailsWith<Exception> { Bundles.parse(bundle.replace("\"Ada\"", "\"Eve\"")) }
        assertFailsWith<Exception> { Mnemonic.toSeed(vectors.getValue("ada").jsonObject.s("mnemonic").replace("abandon", "ability")) }
    }

    @Test
    fun `sealed values and envelopes from TypeScript open here`() {
        val bo = IdentityKeys.fromSeed(Encoding.fromHex(vectors.getValue("bo").jsonObject.s("seedHex")))
        val ada = IdentityKeys.fromSeed(Encoding.fromHex(vectors.getValue("ada").jsonObject.s("seedHex")))
        val seal = vectors.getValue("seal").jsonObject
        val opened = Seal.open(bo.agreementSecret, Encoding.fromBase64Url(seal.s("sealed")), Encoding.utf8(seal.s("aad")))
        assertEquals(seal.s("plaintext"), Encoding.text(opened))

        val envelopes = vectors.getValue("envelopes").jsonObject
        val now = envelopes.getValue("now").jsonPrimitive.long
        val message = envelopes.getValue("message").jsonObject
        val decoded = Envelopes.decode(Encoding.utf8(message.s("json")), ada.signingPublic, now)
        assertEquals(EnvelopeType.MESSAGE, decoded.type)
        assertEquals(message.s("body"), Encoding.text(Envelopes.open(bo, decoded)))
        assertEquals(message.s("json"), decoded.encode())
        for (kind in listOf("ack", "read")) {
            val receipt = envelopes.getValue(kind).jsonObject
            val envelope = Envelopes.decode(Encoding.utf8(receipt.s("json")), bo.signingPublic, now)
            assertEquals(receipt.s("receipt"), Encoding.text(Envelopes.open(ada, envelope)))
        }
        assertFailsWith<Exception> { Envelopes.decode(Encoding.utf8(message.s("json")), bo.signingPublic, now) }
    }

    @Test
    fun `an envelope sealed here opens with the same rules`() {
        val ada = IdentityKeys.generate()
        val bo = IdentityKeys.generate()
        val envelope = Envelopes.seal(ada, "dev_1", bo.directId, bo.agreementPublic, "msg_1", EnvelopeType.MESSAGE, Encoding.utf8("hi"), 1_000, 60_000)
        val decoded = Envelopes.decode(Encoding.utf8(envelope.encode()), ada.signingPublic, 2_000)
        assertEquals("hi", Encoding.text(Envelopes.open(bo, decoded)))
        assertFailsWith<Exception> { Envelopes.decode(Encoding.utf8(envelope.encode()), ada.signingPublic, 200_000) }
    }

    @Test
    fun `backoff bounds match`() {
        for (row in vectors.getValue("backoff").jsonArray) {
            val attempt = row.jsonObject.getValue("attempt").jsonPrimitive.int
            assertEquals(row.jsonObject.getValue("min").jsonPrimitive.long, Backoff.delayMs(attempt) { 0.0 })
            assertEquals(row.jsonObject.getValue("max").jsonPrimitive.long, Backoff.delayMs(attempt) { 1.0 })
        }
    }

    @Test
    fun `bootstrap addresses normalize like contracts bootstrap-url json`() {
        val contract = Contracts.json("bootstrap-url.json").jsonObject
        assertEquals(contract.getValue("hostedDefault").jsonPrimitive.content, BootstrapUrl.DEFAULT)
        assertEquals(BootstrapUrl.Result.Ok(BootstrapUrl.DEFAULT), BootstrapUrl.normalize(BootstrapUrl.DEFAULT))
        assertEquals(BootstrapUrl.DEFAULT, BootstrapUrl.storedOrDefault(null))
        assertEquals(true, BootstrapUrl.usesHttpSignal(BootstrapUrl.DEFAULT))
        assertEquals("https://direct-signaling.apps.grok.bot/signal", BootstrapUrl.httpSignalUrl(BootstrapUrl.DEFAULT))
        assertEquals(false, BootstrapUrl.usesHttpSignal("ws://192.168.1.20:8787"))
        assertEquals(BootstrapUrl.Chosen(BootstrapUrl.DEFAULT, BootstrapUrl.HOSTED_DEFAULT_VERSION), BootstrapUrl.applyHostedDefault(null, 0))
        assertEquals(BootstrapUrl.Chosen(BootstrapUrl.DEFAULT, BootstrapUrl.HOSTED_DEFAULT_VERSION), BootstrapUrl.applyHostedDefault("ws://192.168.1.121:8787", 0))
        assertEquals(BootstrapUrl.Chosen(BootstrapUrl.DEFAULT, BootstrapUrl.HOSTED_DEFAULT_VERSION), BootstrapUrl.applyHostedDefault("192.168.1.121", 0))
        assertEquals(BootstrapUrl.Chosen("ws://192.168.1.121:8787", BootstrapUrl.HOSTED_DEFAULT_VERSION), BootstrapUrl.applyHostedDefault("ws://192.168.1.121:8787", BootstrapUrl.HOSTED_DEFAULT_VERSION))
        assertEquals(BootstrapUrl.Chosen("wss://signals.example.com", BootstrapUrl.HOSTED_DEFAULT_VERSION), BootstrapUrl.applyHostedDefault("wss://signals.example.com", 0))
        val cases = contract.getValue("cases").jsonArray
        for (case in cases) {
            val row = case.jsonObject
            val result = BootstrapUrl.normalize(row.s("input"))
            if (row.containsKey("url")) assertEquals(BootstrapUrl.Result.Ok(row.s("url")), result, row.s("input"))
            else assertEquals(row.s("error"), (result as BootstrapUrl.Result.Invalid).error.code, row.s("input"))
        }
    }

    @Test
    fun `signaling frames encode and decode exactly as contracts signaling json`() {
        val contract = Contracts.json("signaling.json").jsonObject
        val client = contract.getValue("clientToHub").jsonObject
        val hub = contract.getValue("hubToClient").jsonObject
        for ((name, example) in client) {
            val frame = assertNotNull(SignalCodec.decode(example.toString()), name)
            assertEquals(example, Json.parseToJsonElement(SignalCodec.encode(frame)), name)
        }
        for ((name, example) in hub) {
            val frame = assertNotNull(SignalCodec.decode(example.toString()), name)
            assertEquals(example, Json.parseToJsonElement(SignalCodec.encode(frame)), name)
        }
        assertEquals(SignalFrame.Presence("dir_ABCDEFGHJKMNPQRS", true), SignalCodec.decode(hub.getValue("presenceOnline").toString()))
        for (forbidden in contract.getValue("forbidden").jsonArray) {
            assertEquals(null, SignalCodec.decode(forbidden.toString()))
        }
    }
}
