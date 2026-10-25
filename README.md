# OpenBao HSM with SoftHSM2 – Ansible Playbook

This Ansible playbook automates the installation and configuration of **OpenBao HSM Edition** together with **SoftHSM2**. It works on both Debian/Ubuntu and RHEL/Rocky Linux systems.

The playbook performs the following tasks:

- Installs required dependencies (`SoftHSM2`, `OpenSC`)
- Downloads and installs the appropriate OpenBao package based on system architecture (`amd64` or `arm64`)
- Detects the SoftHSM PKCS#11 library path
- Initializes a SoftHSM token if it does not already exist
- Generates an AES key on the token for OpenBao
- Configures the `openbao` user and SoftHSM token permissions
- Creates and configures the OpenBao HCL file for PKCS#11 sealing
- Starts and enables the OpenBao service

All variables such as token label, PINs, AES key label, and key type are configurable.

## Key Variables

| Variable              | Description                            | Default Example |
| --------------------- | -------------------------------------- | --------------- |
| `softhsm_token_label` | SoftHSM token label                    | `openbao-token` |
| `softhsm_pin`         | User PIN for SoftHSM token             | `123456`        |
| `softhsm_so_pin`      | Security Officer PIN for SoftHSM token | `123456`        |
| `softhsm_key_label`   | Label of the AES key to generate       | `bao-root-key`  |
| `softhsm_key_type`    | AES key type and length                | `aes:32`        |
| `openbao_version`     | OpenBao HSM version                    | `2.5.1`         |

## Air-gapped / offline deployment (EL8)

For servers without internet access, use `deploy-offline-el8.sh` — no
compilation happens on the target:

1. **On the online build host** (where the binaries were built):

   ```bash
   ./deploy-offline-el8.sh bundle
   # → offline-el8-bundle-<date>.tar.gz containing the prebuilt
   #   SoftHSM 2.7.0 library + OpenBao PKCS#11 plugin (EL8/glibc-2.28
   #   compatible), .env.example, this script and certs/ if present
   ```

2. **On the air-gapped server** (EL8, x86_64, local dnf repo configured):

   ```bash
   tar xzf offline-el8-bundle-<date>.tar.gz && cd dist-offline-el8
   cp .env.example .env        # pins/labels/addresses — never commit
   # place corporate certs in certs/ (server.crt, server.key, coreCA.crt)
   ./deploy-offline-el8.sh deploy
   ```

The bundle is **fully self-contained**: `rpms/` carries the complete rpm
dependency closure (`openbao`, `softhsm`, `opensc` plus `pcsc-lite`,
`pkgconf`, `polkit`, `openssl`, ... — 16 packages), so the target server
does not need a working dnf repo at all. Already-installed packages are
never downgraded. Binaries are x86_64 EL8 (glibc 2.28 compatible).

Credentials are read from `.env` (git-ignored). No PKI is generated:
the corporate certificates you supply are installed, and the CA is
trusted system-wide so `bao` verifies the endpoint.

`playbooks/site.yml` remains the online/Ansible reference implementation
and documents the desired end state (TLS, raft, PKCS#11 seal, kv-v2).

## Rocky / EL8 Notes

The playbook handles three EL8-specific quirks automatically:

1. **OpenBao HSM packages** – OpenBao ≥ 2.6 ships PKCS#11 sealing via the
   external plugin `openbao-plugin-kms-pkcs11` (no more separate `-hsm`
   packages). The playbook installs the pinned plugin release and the
   required `plugin "kms" "pkcs11"` server config block.

2. **Plugin glibc requirements** – upstream plugin release binaries are
   dynamically linked against glibc ≥ 2.32/2.34 while EL8 ships glibc 2.28.
   The playbook detects this with `ldd` and falls back to building the
   plugin from source with a pinned Go toolchain.

3. **SoftHSM AES-GCM crash** – SoftHSM 2.6.x aborts inside
   `C_EncryptInit`/`C_DecryptInit` when `CKM_AES_GCM` is used with an empty
   AAD (which is exactly what OpenBao sends): `ByteString::operator[]`
   hits a bounds assert under EL8's hardened libstdc++. Fixed upstream in
   SoftHSM 2.7.0, which the playbook therefore builds into `/usr/local`
   and the seal uses `/usr/local/lib/softhsm/libsofthsm2.so`.

After convergence the playbook also initializes the server with PKCS#11
auto-unseal (`bao operator init -recovery-shares=1 -recovery-threshold=1`),
enables the KV v2 mount at `secret/`, and asserts that the node is
initialized and **unsealed**. Initial credentials (root token + recovery
key) are stored in `/root/init.json` (mode 0600). The CA and TLS flow uses
a locally generated internal CA, trusted system-wide, so the CLI works via
`BAO_ADDR` and `BAO_CACERT` from `/etc/profile.d/66-set-bao-addr.sh`.

## Manual Steps

If you prefer to perform the setup manually without Ansible, the general steps are:

1. **Install Dependencies**

   - Install `SoftHSM2` and `OpenSC` using your system package manager.

2. **Download OpenBao**

   - Download the OpenBao HSM compatible package corresponding to your system architecture.

3. **Install OpenBao**

   - Install the downloaded package using your system’s package manager (e.g., `apt` or `dnf`).

4. **Initialize SoftHSM Token**

   - Check available slots:

     ```bash
     softhsm2-util --show-slots
     ```

   - Initialize a token (replace labels and PINs as needed):

     ```bash
     softhsm2-util --init-token --slot 0 --label openbao-token --pin 123456 --so-pin 123456
     ```

5. **Generate AES Key on the Token**

   - Use `pkcs11-tool` to create the AES key:

     ```bash
     pkcs11-tool --module /path/to/libsofthsm2.so \
       --token-label openbao-token \
       --pin 123456 \
       --keygen \
       --key-type aes:32 \
       --label bao-root-key
     ```

6. **Configure Permissions**

   - Ensure the `openbao` user can access the token directory and files:

     - Create or verify a `softhsm` group.
     - Add `openbao` to this group.
     - Set the token directory permissions so that owner and group have full access.

7. **Configure OpenBao**

   - Create `/etc/openbao/openbao.hcl` with the PKCS#11 seal configuration pointing to your SoftHSM token and AES key.

8. **Start OpenBao**

   - Start the OpenBao service (systemd) and ensure it is enabled at boot.

This playbook abstracts all these steps and handles cross-platform differences (Debian vs. Rocky Linux), including:

- Detecting the correct library path for PKCS#11
- Ensuring idempotent creation of tokens and AES keys
- Setting correct file and directory permissions for the `openbao` user

## Author

- Chris van Meer - <chris@atcomputing.nl>
