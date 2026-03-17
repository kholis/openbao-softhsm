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
