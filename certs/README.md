# Corporate certificates for offline deployment

Place the three files supplied by your corporate PKI here **before**
running `./deploy-offline-el8.sh deploy`:

| file         | mode | used for                                   |
|--------------|------|--------------------------------------------|
| `server.crt` | 0644 | OpenBao TLS listener certificate           |
| `server.key` | 0600 | matching private key (never commit!)       |
| `coreCA.crt` | 0644 | issuing/intermediate CA — trusted system-  |
|              |      | wide so the `bao` CLI verifies the endpoint|

This directory is git-ignored. `server.key` must not leave the target
server's trust boundary.
