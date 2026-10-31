# Bootstrap

libp2p bootstrap peers are intentionally empty. DIRECT does not ship a hosted peer list. When a Hermes-capable libp2p dialer is attached to `Libp2pTransport`, put the operator's own multiaddrs here. Do not put message contents or private keys in this directory.

Phones in different places rendezvous through `infrastructure/signaling`. That hub keeps public bundles in memory and forwards WebRTC session descriptions. It is not a message store.
