# TURN

WebRTC can need a TURN server when a direct path cannot be negotiated. Run your own. A starting `coturn` listener:

```text
listening-port=3478
fingerprint
lt-cred-mech
realm=direct.local
# Provide credentials out of band. Do not commit them.
```

The signaling server in `../signaling` exchanges offers and answers only. It is not a TURN server and it does not accept message payloads.
