# Relay

The relay is optional and off by default.

`WakuTransport` forwards ciphertext to a topic named for the recipient. If nobody is listening and temporary storage is off, the send fails and the local queue keeps the message. If storage is on, the ciphertext is kept until its expiry and handed over once, then dropped.

nwaku or `@waku/sdk` can replace `MemoryWakuNode` later. Storage on those nodes should stay disabled unless the operator shows users the same disclosure the settings screen shows. A relay acknowledgement is not a recipient acknowledgement.
