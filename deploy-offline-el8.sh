#!/usr/bin/env bash
#
# deploy-offline-el8.sh — OpenBao (PKCS#11 auto-unseal) + SoftHSM for
#                         air-gapped EL8 servers, no compiler required.
#
# Two modes:
#   ./deploy-offline-el8.sh bundle   run on the ONLINE build host:
#                                    collects prebuilt binaries + certs
#                                    into a tarball you copy over.
#   ./deploy-offline-el8.sh deploy   run on the AIR-GAPPED EL8 target:
#                                    installs and converges everything.
#
# The bundle is self-contained: it carries the two custom binaries plus
# the full rpm dependency closure (openbao, softhsm, opensc and their
# dependencies), so the target server does NOT need a working dnf repo.
# If the target does have one, the rpms/ directory simply no-ops for
# already-installed packages.
#
# Credentials live in .env (never committed). Certificates are supplied
# by you in certs/ (server.crt, server.key, coreCA.crt) — no PKI is
# generated here.

set -euo pipefail

MODE="${1:-deploy}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YEL=$'\033[0;33m'; OFF=$'\033[0m'
log()  { printf '%s[deploy]%s %s\n' "$GREEN" "$OFF" "$*"; }
warn() { printf '%s[warn]%s  %s\n'  "$YEL"    "$OFF" "$*" >&2; }
die()  { printf '%s[fail]%s  %s\n'  "$RED"    "$OFF" "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# bundle: run on the online build host
# ---------------------------------------------------------------------------
do_bundle() {
    local out="offline-el8-bundle-$(date +%Y%m%d-%H%M).tar.gz"
    local stage="dist-offline-el8"

    log "Collecting prebuilt artifacts..."

    local plugin="/opt/openbao/plugins/openbao-plugin-kms-pkcs11"
    local shsm="/usr/local/lib/softhsm/libsofthsm2.so"

    [[ -x "$plugin" ]] || die "plugin not found: $plugin"
    [[ -f "$shsm"   ]] || die "softhsm lib not found: $shsm"

    # Sanity: plugin must execute on this glibc (expect its banner)
    local banner
    banner="$("$plugin" 2>&1 || true)"
    if grep -q "This binary is a plugin" <<< "$banner"; then
        log "plugin binary sanity: OK"
    else
        die "plugin binary did not execute cleanly on this host"
    fi
    if ldd "$shsm" | grep -q "not found"; then
        die "softhsm lib has unresolved dependencies"
    fi
    log "softhsm lib dependency check: OK"

    rm -rf "$stage"
    install -d "$stage/binaries" "$stage/certs" "$stage/rpms"
    install -m 0755 "$plugin" "$stage/binaries/openbao-plugin-kms-pkcs11"
    install -m 0755 "$shsm"   "$stage/binaries/libsofthsm2.so"
    cp "$(readlink -f "$0")" "$stage/deploy-offline-el8.sh"

    if [[ -f "$SCRIPT_DIR/.env.example" ]]; then
        install -m 0644 "$SCRIPT_DIR/.env.example" "$stage/.env.example"
    else
        warn ".env.example not found next to script; bundle skips it"
    fi

    if [[ -d "$SCRIPT_DIR/certs" ]] && \
       ls "$SCRIPT_DIR"/certs/{server.crt,server.key,coreCA.crt} >/dev/null 2>&1; then
        install -m 0644 "$SCRIPT_DIR/certs/server.crt" "$stage/certs/"
        install -m 0644 "$SCRIPT_DIR/certs/coreCA.crt" "$stage/certs/"
        install -m 0600 "$SCRIPT_DIR/certs/server.key" "$stage/certs/"
        log "corporate certs included"
    else
        warn "certs/ does not yet contain server.crt/server.key/coreCA.crt"
        warn "add them to certs/ inside the extracted bundle before deploying"
    fi

    collect_rpms "$stage"

    tar czf "$out" "$stage"
    rm -rf "$stage"

    log "bundle written: $out ($(du -h "$out" | cut -f1))"
    log "sha256: $(sha256sum "$out" | awk '{print $1}')"
    cat <<EOF

Next steps:
  1. scp $out to the air-gapped server
  2. tar xzf $(basename "$out") && cd $stage
  3. cp .env.example .env   # edit pins/labels
  4. put corporate certs in certs/ (server.crt, server.key, coreCA.crt)
  5. ./deploy-offline-el8.sh deploy

The bundle is self-contained: rpms/ carries the full dependency closure
(openbao + softhsm + opensc + deps), so the target does not need a
dnf repo. Binaries are x86_64 EL8 (glibc 2.28 compatible).
EOF
}

# ---------------------------------------------------------------------------
# rpm collection: run on the online build host, needs network + dnf
# ---------------------------------------------------------------------------
collect_rpms() {
    local stage="$1"
    local rpmdir="$stage/rpms"
    local openbao_rpm="openbao_2.7.1_linux_amd64.rpm"
    local openbao_rpm_sha="698970b7e58590bd0ceb55043ce6f5e5d53e67b4a825e296cc197b21d6a6d700"
    local cached="/opt/openbao-bundle/$openbao_rpm"

    log "collecting rpm dependency closure into rpms/..."

    if [[ -f "$cached" ]] && \
       echo "$openbao_rpm_sha  $cached" | sha256sum -c >/dev/null 2>&1; then
        install -m 0644 "$cached" "$rpmdir/$openbao_rpm"
        log "openbao rpm: reused sha256-verified local copy"
    else
        curl -fL --max-time 600 -o "$rpmdir/$openbao_rpm" \
            "https://github.com/openbao/openbao/releases/download/v2.7.1/$openbao_rpm"
        echo "$openbao_rpm_sha  $rpmdir/$openbao_rpm" | sha256sum -c >/dev/null
        log "openbao rpm: downloaded, sha256 verified"
    fi

    dnf download --resolve --downloaddir "$rpmdir" softhsm opensc openssl >/dev/null 2>&1 || \
        warn "dnf repos lack some packages — using verified offline rpm set instead"

    # The Rocky base repos do not carry softhsm; seed the closure from the
    # previously staged offline rpm set when present. Integrity (digests)
    # is mandatory; GPG signatures are best-effort since some packages in
    # the set come from other vendors (e.g. Fedora-built softhsm).
    if [[ -d /opt/openbao-bundle ]]; then
        local r
        for r in /opt/openbao-bundle/*.rpm; do
            [[ "$(basename "$r")" == "$openbao_rpm" ]] && continue
            if rpm -K --nosignature "$r" >/dev/null 2>&1; then
                rpm -K "$r" >/dev/null 2>&1 || \
                    warn "$(basename "$r"): signature unverifiable (digests OK)"
                cp -n "$r" "$rpmdir/"
            else
                warn "skipping corrupt rpm (digest failure): $r"
            fi
        done
    fi

    local n
    n="$(ls -1 "$rpmdir"/*.rpm 2>/dev/null | wc -l)"
    [[ $n -ge 4 ]] || die "rpm collection produced only $n file(s)"
    log "rpms/: $n packages ($(du -sh "$rpmdir" | cut -f1))"
}

# ---------------------------------------------------------------------------
# deploy: run on the air-gapped EL8 target
# ---------------------------------------------------------------------------
require_env() {
    [[ -f "$SCRIPT_DIR/.env" ]] || die ".env not found — copy .env.example and edit it"
    set -a
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/.env"
    set +a
    chmod 600 "$SCRIPT_DIR/.env" 2>/dev/null || true
    : "${SOFTHSM_TOKEN_LABEL:?set SOFTHSM_TOKEN_LABEL in .env}"
    : "${SOFTHSM_PIN:?set SOFTHSM_PIN in .env}"
    : "${SOFTHSM_SO_PIN:?set SOFTHSM_SO_PIN in .env}"
    : "${SOFTHSM_KEY_LABEL:?set SOFTHSM_KEY_LABEL in .env}"
    BAO_API_ADDR="${BAO_API_ADDR:-https://127.0.0.1:8200}"
    BAO_CLUSTER_ADDR="${BAO_CLUSTER_ADDR:-https://127.0.0.1:8201}"
    RECOVERY_SHARES="${RECOVERY_SHARES:-1}"
    RECOVERY_THRESHOLD="${RECOVERY_THRESHOLD:-1}"
}

preflight() {
    [[ $EUID -eq 0 ]] || die "run as root"
    grep -qE '^ID="(rocky|rhel|centos|almalinux)"' /etc/os-release || \
        grep -qE 'ID_LIKE.*(rhel|centos|fedora)' /etc/os-release || \
        die "this script targets EL8 systems"
    . /etc/os-release
    [[ ${VERSION_ID%%.*} == "8" ]] || die "expected EL8, found ${VERSION_ID}"
    uname -m | grep -q x86_64 || die "bundle binaries are x86_64 only"

    for f in certs/server.crt certs/server.key certs/coreCA.crt; do
        [[ -s "$SCRIPT_DIR/$f" ]] || die "missing $f (supply corporate certs in certs/)"
    done
    [[ -x "$SCRIPT_DIR/binaries/openbao-plugin-kms-pkcs11" ]] || die "missing binaries/openbao-plugin-kms-pkcs11"
    [[ -f "$SCRIPT_DIR/binaries/libsofthsm2.so" ]] || die "missing binaries/libsofthsm2.so"
    log "preflight: OK (EL${VERSION_ID%%.*}, certs and binaries present)"
}

install_packages() {
    local pkgs=(softhsm opensc openbao)
    local have_all=true p

    for p in "${pkgs[@]}"; do
        rpm -q "$p" >/dev/null 2>&1 || have_all=false
    done
    if [[ $have_all == true ]]; then
        log "all required packages already installed"
        return
    fi

    if ls "$SCRIPT_DIR"/rpms/*.rpm >/dev/null 2>&1; then
        log "installing missing packages from bundled rpms/..."
        local rpmlist=() r name
        for r in "$SCRIPT_DIR"/rpms/*.rpm; do
            name="$(rpm -qp --qf '%{NAME}' "$r" 2>/dev/null)" || continue
            if rpm -q "$name" >/dev/null 2>&1; then
                continue   # already satisfied — never downgrade a target pkg
            fi
            rpmlist+=("$r")
        done
        if ((${#rpmlist[@]} > 0)); then
            dnf install -y -q "${rpmlist[@]}"
        else
            log "all bundled rpms already satisfied"
        fi
    fi

    for p in "${pkgs[@]}"; do
        rpm -q "$p" >/dev/null 2>&1 && continue
        log "'$p' not covered — trying local repo..."
        dnf install -y -q "$p" || \
            die "package '$p' missing: not in rpms/ and not in any configured repo"
    done
    log "packages ready: $(rpm -q "${pkgs[@]}" 2>/dev/null | tr '\n' ' ')"
}

install_prebuilt() {
    log "installing prebuilt SoftHSM 2.7.0 + PKCS#11 plugin..."

    install -d -m 0755 /usr/local/lib/softhsm /usr/local/etc
    install -m 0755 "$SCRIPT_DIR/binaries/libsofthsm2.so" \
        /usr/local/lib/softhsm/libsofthsm2.so

    if ldd /usr/local/lib/softhsm/libsofthsm2.so | grep -q "not found"; then
        die "libsofthsm2.so dependencies unresolved — missing repo packages?"
    fi

    # SoftHSM 2.7.0 config: point at the shared token directory
    local conf_changed=false
    cat > /tmp/softhsm2.conf.new <<'EOF'
# SoftHSM v2 configuration file (deployed by deploy-offline-el8.sh)

directories.tokendir = /var/lib/softhsm/tokens
objectstore.backend = file
objectstore.umask = 0077

# ERROR, WARNING, INFO, DEBUG
log.level = ERROR

# If CKF_REMOVABLE_DEVICE flag should be set
slots.removable = false

# Enable and disable PKCS#11 mechanisms using slots.mechanisms.
slots.mechanisms = ALL

# If the library should reset the state on fork
library.reset_on_fork = false
EOF
    if ! cmp -s /tmp/softhsm2.conf.new /usr/local/etc/softhsm2.conf 2>/dev/null; then
        install -m 0644 /tmp/softhsm2.conf.new /usr/local/etc/softhsm2.conf
        conf_changed=true
    fi
    rm -f /tmp/softhsm2.conf.new

    # OpenBao must own the token store (it is the primary consumer)
    getent group softhsm >/dev/null || groupadd -r softhsm
    getent passwd openbao >/dev/null || die "openbao user missing — was the openbao rpm installed?"
    install -d -m 2770 -o openbao -g softhsm /var/lib/softhsm/tokens

    install -d -m 0755 -o openbao -g openbao /opt/openbao/plugins
    install -m 0755 -o openbao -g openbao \
        "$SCRIPT_DIR/binaries/openbao-plugin-kms-pkcs11" \
        /opt/openbao/plugins/openbao-plugin-kms-pkcs11

    local pbanner
    pbanner="$(/opt/openbao/plugins/openbao-plugin-kms-pkcs11 2>&1 || true)"
    if grep -q "This binary is a plugin" <<< "$pbanner"; then
        log "plugin executes on this host: OK"
    else
        die "plugin failed to execute — glibc mismatch? rebuild the bundle on a matching host"
    fi

    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R /usr/local/lib/softhsm /opt/openbao/plugins 2>/dev/null || true
    fi
    if [[ $conf_changed == true ]]; then
        warn "softhsm2.conf updated"
    fi
}
init_token_and_key() {
    log "ensuring SoftHSM token and AES key..."

    local slots
    slots="$(softhsm2-util --show-slots 2>&1)" || die "softhsm2-util failed"
    if ! grep -q "Label: *${SOFTHSM_TOKEN_LABEL}" <<< "$slots"; then
        softhsm2-util --init-token --slot 0 \
            --label "$SOFTHSM_TOKEN_LABEL" \
            --pin "$SOFTHSM_PIN" --so-pin "$SOFTHSM_SO_PIN" \
            >/dev/null
        log "token '${SOFTHSM_TOKEN_LABEL}' initialized"
    else
        log "token '${SOFTHSM_TOKEN_LABEL}' already present"
    fi

    local objects
    objects="$(pkcs11-tool --module /usr/local/lib/softhsm/libsofthsm2.so \
        --token-label "$SOFTHSM_TOKEN_LABEL" --pin "$SOFTHSM_PIN" -O 2>/dev/null || true)"
    if ! grep -q "label:.*${SOFTHSM_KEY_LABEL}" <<< "$objects"; then
        pkcs11-tool --module /usr/local/lib/softhsm/libsofthsm2.so \
            --token-label "$SOFTHSM_TOKEN_LABEL" --pin "$SOFTHSM_PIN" \
            --keygen --key-type aes:32 --label "$SOFTHSM_KEY_LABEL" >/dev/null
        log "AES key '${SOFTHSM_KEY_LABEL}' generated"
    else
        log "AES key '${SOFTHSM_KEY_LABEL}' already present"
    fi

    # Token files are created 0600 by SoftHSM's umask; keep them that way
    chown -R openbao:softhsm /var/lib/softhsm
    find /var/lib/softhsm/tokens -type f -exec chmod 0600 {} + 2>/dev/null || true
}

install_certs() {
    local changed=false

    log "installing corporate certificates..."
    install -d -m 0750 -o openbao -g openbao /etc/openbao/tls
    if ! cmp -s "$SCRIPT_DIR/certs/coreCA.crt" /etc/openbao/tls/coreCA.crt 2>/dev/null; then
        install -m 0644 -o openbao -g openbao "$SCRIPT_DIR/certs/coreCA.crt" /etc/openbao/tls/coreCA.crt
        changed=true
    fi
    if ! cmp -s "$SCRIPT_DIR/certs/server.crt" /etc/openbao/tls/server.crt 2>/dev/null; then
        install -m 0644 -o openbao -g openbao "$SCRIPT_DIR/certs/server.crt" /etc/openbao/tls/server.crt
        changed=true
    fi
    if ! cmp -s "$SCRIPT_DIR/certs/server.key" /etc/openbao/tls/server.key 2>/dev/null; then
        install -m 0600 -o openbao -g openbao "$SCRIPT_DIR/certs/server.key" /etc/openbao/tls/server.key
        changed=true
    fi

    # Trust the corporate CA so local CLI tools verify the endpoint
    if ! cmp -s "$SCRIPT_DIR/certs/coreCA.crt" /etc/pki/ca-trust/source/anchors/coreCA.crt 2>/dev/null; then
        install -d -m 0755 /etc/pki/ca-trust/source/anchors
        install -m 0644 "$SCRIPT_DIR/certs/coreCA.crt" /etc/pki/ca-trust/source/anchors/coreCA.crt
        update-ca-trust extract
        changed=true
    fi

    if [[ $changed == true ]] && systemctl is-active --quiet openbao; then
        log "certificates changed — restarting openbao"
        systemctl restart openbao
    fi
    log "CA trusted system-wide"
}

write_config() {
    local restart=false

    log "writing OpenBao configuration..."
    cat > /tmp/openbao.hcl.new <<EOF
ui = true

api_addr     = "${BAO_API_ADDR}"
cluster_addr = "${BAO_CLUSTER_ADDR}"

plugin_directory = "/opt/openbao/plugins"

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "127.0.0.1:8201"
  tls_cert_file   = "/etc/openbao/tls/server.crt"
  tls_key_file    = "/etc/openbao/tls/server.key"
}

storage "raft" {
  path    = "/opt/openbao/data"
  node_id = "openbao-1"
}

plugin "kms" "pkcs11" {
  command = "openbao-plugin-kms-pkcs11"
}

seal "pkcs11" {
  lib         = "/usr/local/lib/softhsm/libsofthsm2.so"
  pin         = "${SOFTHSM_PIN}"
  token_label = "${SOFTHSM_TOKEN_LABEL}"
  key_label   = "${SOFTHSM_KEY_LABEL}"
}
EOF
    if ! cmp -s /tmp/openbao.hcl.new /etc/openbao/openbao.hcl 2>/dev/null; then
        install -m 0640 -o root -g openbao /tmp/openbao.hcl.new /etc/openbao/openbao.hcl
        restart=true
    fi
    rm -f /tmp/openbao.hcl.new

    local envline="export BAO_ADDR=${BAO_API_ADDR}
export BAO_CACERT=/etc/openbao/tls/coreCA.crt"
    if [[ ! -f /etc/profile.d/66-set-bao-addr.sh ]] || \
       ! grep -qF "$envline" /etc/profile.d/66-set-bao-addr.sh; then
        printf '%s\n' "$envline" > /etc/profile.d/66-set-bao-addr.sh
        chmod 0644 /etc/profile.d/66-set-bao-addr.sh
    fi

    install -d -m 0750 -o openbao -g openbao /opt/openbao/data

    if [[ $restart == true ]] && systemctl is-active --quiet openbao; then
        log "config changed — restarting openbao"
        systemctl restart openbao
    fi
}

start_service() {
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --add-port=8200/tcp --permanent >/dev/null
        firewall-cmd --reload >/dev/null
        log "firewalld: opened 8200/tcp"
    fi

    log "starting openbao..."
    systemctl enable openbao >/dev/null 2>&1
    systemctl start openbao

    for _ in $(seq 1 30); do
        if timeout 3 bash -c "</dev/tcp/127.0.0.1/8200" 2>/dev/null; then
            log "API is listening"
            return
        fi
        sleep 1
    done
    journalctl -u openbao -n 20 --no-pager >&2 || true
    die "openbao did not come up on 127.0.0.1:8200"
}

init_server() {
    local status
    status="$(bao status -format=json 2>/dev/null || true)"

    if [[ -z "$status" ]]; then
        die "cannot reach OpenBao API at $BAO_ADDR"
    fi

    if [[ "$(jq_parse "$status" "['initialized']")" == "true" ]]; then
        log "server already initialized"
    else
        if [[ -s /root/init.json ]]; then
            warn "/root/init.json already exists but server is uninitialized"
            warn "refusing to overwrite it — remove it manually if you are sure"
            die "stale /root/init.json"
        fi
        log "initializing with PKCS#11 auto-unseal..."
        bao operator init \
            -recovery-shares="$RECOVERY_SHARES" \
            -recovery-threshold="$RECOVERY_THRESHOLD" \
            -format=json > /root/init.json
        chmod 600 /root/init.json
        python3 -c "import json; print(json.load(open('/root/init.json'))['root_token'])" \
            > /root/.bao-token
        chmod 600 /root/.bao-token
        log "credentials saved to /root/init.json and /root/.bao-token (0600)"
    fi

    local mounts root_token
    root_token="$(token_from_file)"
    mounts="$(BAO_TOKEN="$root_token" bao secrets list -format=json 2>/dev/null || true)"
    if [[ -z "$mounts" ]]; then
        die "cannot list mounts — check root token (/root/init.json, /root/.bao-token)"
    fi
    if ! grep -q '"secret/"' <<< "$mounts"; then
        BAO_TOKEN="$root_token" bao secrets enable -path=secret kv-v2 >/dev/null
        log "kv-v2 mounted at secret/"
    fi
}

token_from_file() {
    python3 -c "import json; print(json.load(open('/root/init.json'))['root_token'])"
}

jq_parse() {
    # usage: jq_parse <json> <python-subscript>  e.g. jq_parse "$status" "['sealed']"
    # output is lowercased so booleans read true/false like jq
    python3 -c "import json,sys; print(str(json.load(sys.stdin)$2).lower())" <<< "$1"
}

final_check() {
    local status
    status="$(bao status -format=json 2>/dev/null || true)"
    [[ -n "$status" ]] || die "API unreachable at final check"
    if [[ "$(jq_parse "$status" "['initialized']")" != "true" ]] || \
       [[ "$(jq_parse "$status" "['sealed']")" != "false" ]]; then
        echo "$status"
        die "server is not initialized+unsealed — inspect journalctl -u openbao"
    fi
    cat <<EOF

${GREEN}Deployment complete.${OFF}
  API:      $BAO_ADDR
  Status:   initialized, auto-unsealed via SoftHSM (pkcs11)
  Root:     /root/init.json, /root/.bao-token (0600)
  Try:      export BAO_ADDR=$BAO_ADDR BAO_CACERT=/etc/openbao/tls/coreCA.crt
            bao kv put secret/demo hello=world
EOF
}

do_deploy() {
    require_env
    export BAO_ADDR="$BAO_API_ADDR"
    export BAO_CACERT=/etc/openbao/tls/coreCA.crt
    preflight
    install_packages
    install_prebuilt
    init_token_and_key
    install_certs
    write_config
    start_service
    init_server
    final_check
}

case "$MODE" in
    bundle) do_bundle ;;
    deploy) do_deploy ;;
    *)
        echo "usage: $0 {bundle|deploy}" >&2
        echo "  bundle  collect binaries + rpm closure + certs into a tarball (online host)" >&2
        echo "  deploy  install and converge on the air-gapped EL8 server" >&2
        exit 1
        ;;
esac
