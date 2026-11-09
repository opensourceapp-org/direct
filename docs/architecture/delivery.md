# Delivery

When Alice sends Bob a message:

1. The message is sealed to Bob's agreement key and signed by Alice.
2. The ciphertext and the local plaintext are saved in one transaction, with a queue row.
3. The router tries a direct transport, then an enabled relay.
4. If Bob is unavailable, the queue row stays. The message is not deleted.
5. Retries use exponential backoff from 1 second, capped at 5 minutes, with jitter.
6. Rows past their expiry are marked expired and removed from the queue. The message row remains.

When Bob is reachable:

1. His device checks the signature against Alice's contact record.
2. Duplicate message ids are ignored and acknowledged again.
3. The plaintext is stored in Bob's database.
4. Bob sends a signed, sealed acknowledgement.
5. Alice verifies that acknowledgement and only then marks the message delivered and deletes the queue row.

A relay accept sets the transport hint to `relay` and leaves the status `pending`. Read receipts are a second signed envelope and never downgrade a message that is already read.

A group chat still uses one-shot seals. The sender writes one local message and queues a sealed copy for each other member under the same logical id. Each recipient `ack`s their copy; the sender marks the message delivered only when no copies remain in the queue.

Blocked contacts are rejected before send and dropped on receive.
