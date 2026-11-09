package app.direct.core.signaling

import app.direct.core.Encoding

/** Bytes the device signs to prove it holds the DIRECT ID's signing key for this bootstrap nonce. */
object SignalProof {
    const val PREFIX = "DIRECT-SIGNAL/1"

    fun message(nonce: String, directId: String): ByteArray = Encoding.utf8("$PREFIX\n$nonce\n$directId")
}
