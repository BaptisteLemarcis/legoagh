#!/bin/bash

# Exit the script if a pipeline fails (-e), prevent accidental filename
# expansion (-f), and consider undefined variables as errors (-u).
set -e -f -u

# Env configuration
#
# DOMAIN_NAME       Main domain name we're obtaining a wildcard certificate for.
# DNS_PROVIDER      DNS provider lego uses to prove that you're in control of
# 					the domain. The current version supports the following hosts:
# 					"cloudflare", "digitalocean", "dreamhost", "duckdns" and "godaddy".
# EMAIL				Your email address.
#
# CloudFlare
# ---
# If you're using CloudFlare, you must specify the API token:
# https://developers.cloudflare.com/api/tokens/create
#
# CLOUDFLARE_DNS_API_TOKEN		Your API token.
#
#
# DigitalOcean
# ---
# If you're using DigitalOcean, you must specify the API token:
# https://cloud.digitalocean.com/account/api/tokens
#
# DO_AUTH_TOKEN		Your API token.
#
#
# DreamHost
# ---
# If you're using DreamHost you must specify the API key:
# https://panel.dreamhost.com/?tree=billing.api
#
# DREAMHOST_API_KEY     Your API key
#
#
# Duck DNS
# ---
# If you're using DuckDNS you must specify the API token
#
# DUCKDNS_TOKEN         Your API token
#
#
# GoDaddy
# ---
# If you're using GoDaddy, you must specify the API secret and key. The API
# credentials can be created here: https://developer.godaddy.com/keys
#
# GODADDY_API_KEY				API key.
# GODADDY_API_SECRET			API secret.


LEGO_DIR="/opt/lego"
LEGO_PATH="/opt/lego"
LEGO_BIN="${LEGO_DIR}/lego"
HOOK="${1:-/opt/lego/deploy-hook.sh}"
RENEW_DAYS="${RENEW_DAYS:-30}"
DNS_RESOLVERS="${DNS_RESOLVERS:-1.1.1.1:53}"

# Function error_exit is an echo wrapper that writes to stderr and stops the
# script execution with code 1.
error_exit() {
    echo "$1" 1>&2

    exit 1
}

# Function log is an echo wrapper that writes to stderr if the caller
# requested verbosity level greater than 0.  Otherwise, it does nothing.
log() {
    if [ "$verbose" -gt '0' ]; then
        echo "$1" 1>&2
    fi
}

check_env() {
    if [ -z "${DOMAIN_NAME+x}" ]; then
        error_exit "DOMAIN_NAME must be specified"
    fi

    if [ -z "${DNS_PROVIDER+x}" ]; then
        error_exit "DNS_PROVIDER must be specified"
    fi

    if [ -z "${EMAIL+x}" ]; then
        error_exit "EMAIL must be specified"
    fi

    if [ "${DNS_PROVIDER}" != 'godaddy' ] && [ "${DNS_PROVIDER}" != 'cloudflare' ] && [ "${DNS_PROVIDER}" != 'digitalocean' ] && [ "${DNS_PROVIDER}" != "dreamhost" ] && [ "${DNS_PROVIDER}" != 'duckdns' ]; then
        error_exit "DNS provider ${DNS_PROVIDER} is not supported"
    fi

    if [ "${DNS_PROVIDER}" = 'cloudflare' ]; then
        if [ -z "${CLOUDFLARE_DNS_API_TOKEN+x}" ]; then
            error_exit "CLOUDFLARE_DNS_API_TOKEN must be specified"
        fi
    fi

    if [ "${DNS_PROVIDER}" = 'godaddy' ]; then
        if [ -z "${GODADDY_API_KEY+x}" ]; then
            error_exit "GODADDY_API_KEY must be specified"
        fi

        if [ -z "${GODADDY_API_SECRET+x}" ]; then
            error_exit "GODADDY_API_SECRET must be specified"
        fi
    fi

    if [ "${DNS_PROVIDER}" = 'digitalocean' ]; then
        if [ -z "${DO_AUTH_TOKEN+x}" ]; then
            error_exit "DO_AUTH_TOKEN must be specified"
        fi
    fi

    if [ "${DNS_PROVIDER}" = 'dreamhost' ]; then
        if [ -z "${DREAMHOST_API_KEY+x}" ]; then
            error_exit "DREAMHOST_API_KEY must be specified"
        fi
    fi	

    if [ "${DNS_PROVIDER}" = 'duckdns' ]; then
        if [ -z "${DUCKDNS_TOKEN+x}" ]; then
            error_exit "DUCKDNS_TOKEN must be specified"
        fi
    fi	

}

# Function set_os sets the os if needed and validates the value.
set_os() {
    # Set if needed.
    if [ "$os" = '' ]; then
        os="$(uname -s)"
        case "$os" in

        'Darwin')
            os='darwin'
            ;;
        'FreeBSD')
            os='freebsd'
            ;;
        'Linux')
            os='linux'
            ;;
        'OpenBSD')
            os='openbsd'
            ;;
        esac
    fi

    # Validate.
    case "$os" in

    'darwin' | 'freebsd' | 'linux' | 'openbsd')
        # All right, go on.
        ;;
    *)
        error_exit "unsupported operating system: '$os'"
        ;;
    esac

    # Log.
    log "operating system: $os"
}

# Function set_cpu sets the cpu if needed and validates the value.
set_cpu() {
    # Set if needed.
    if [ "$cpu" = '' ]; then
        cpu="$(uname -m)"
        case "$cpu" in

        'x86_64' | 'x86-64' | 'x64' | 'amd64')
            cpu='amd64'
            ;;
        'i386' | 'i486' | 'i686' | 'i786' | 'x86')
            cpu='386'
            ;;
        'armv5l')
            cpu='armv5'
            ;;
        'armv6l')
            cpu='armv6'
            ;;
        'armv7l' | 'armv8l')
            cpu='armv7'
            ;;
        'aarch64' | 'arm64')
            cpu='arm64'
            ;;
        'mips' | 'mips64')
            if is_little_endian; then
                cpu="${cpu}le"
            fi
            cpu="${cpu}_softfloat"
            ;;
        esac
    fi

    # Validate.
    case "$cpu" in

    'amd64' | '386' | 'armv5' | 'armv6' | 'armv7' | 'arm64')
        # All right, go on.
        ;;
    'mips64le_softfloat' | 'mips64_softfloat' | 'mipsle_softfloat' | 'mips_softfloat')
        # That's right too.
        ;;
    *)
        error_exit "unsupported cpu type: $cpu"
        ;;
    esac

    # Log.
    log "cpu type: $cpu"
}

download_lego() {
    release=$(curl -fsSL "https://api.github.com/repos/go-acme/lego/releases/latest") || {
        echo "Could not reach GitHub API, keeping current lego." >&2
        return 0
    }

    latest=$(printf '%s' "$release" | grep -o '"tag_name": *"[^"]*"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    if [ -z "$latest" ]; then
        echo "Could not determine latest lego version." >&2
        return 0
    fi

    installed=""
    if [ -x "$LEGO_BIN" ]; then
        installed=$("$LEGO_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    fi

    if [ "$installed" = "$latest" ]; then
        echo "lego ${installed} is up to date."
        return 0
    fi

    if [ -n "$installed" ] && [ "${installed%%.*}" != "${latest%%.*}" ]; then
        echo "lego ${latest} is a new major version (installed: ${installed}). Skipping, upgrade manually." >&2
        return 0
    fi

    echo "Updating lego ${installed:-none} -> ${latest}"

    tmp=$(mktemp -d)
    assets=$(printf '%s' "$release" | grep -o '"browser_download_url": *"[^"]*"' | grep -o 'https://[^"]*')
    tarURL=$(printf '%s\n' "$assets" | grep "_${os}_${cpu}\.tar\.gz$" | head -n1)
    sumURL=$(printf '%s\n' "$assets" | grep 'checksums\.txt$' | head -n1)
    tarName=$(basename "$tarURL")

    if [ -z "$tarURL" ] || [ -z "$sumURL" ] \
        || ! curl -fsSL "$tarURL" -o "$tmp/$tarName" \
        || ! curl -fsSL "$sumURL" -o "$tmp/checksums.txt" \
        || ! (cd "$tmp" && grep " ${tarName}\$" checksums.txt | sha256sum -c - >/dev/null) \
        || ! tar xzf "$tmp/$tarName" -C "$tmp" lego; then
        echo "lego download or verification failed, keeping current version." >&2
        rm -rf "$tmp"
        return 0
    fi

    mkdir -p "$LEGO_DIR"
    chmod 755 "$tmp/lego"
    mv -f "$tmp/lego" "$LEGO_BIN"
    rm -rf "$tmp"
    "$LEGO_BIN" --version
}
run_lego_common() {
    provider="$1"

    set -- run \
        --accept-tos \
        --dns "$provider" \
        --dns.resolvers "$DNS_RESOLVERS" \
        --domains "$wildcardDomainName" \
        --domains "$domainName" \
        --email "$email" \
        --path "$LEGO_PATH" \
        --renew-days "$RENEW_DAYS" \
        --cert.timeout 600

    if [ -n "${SERVER:-}" ] && [ -n "${EAB_KID:-}" ] && [ -n "${EAB_HMAC:-}" ]; then
        set -- "$@" \
            --server "$SERVER" \
            --eab \
            --eab-kid "$EAB_KID" \
            --eab-hmac "$EAB_HMAC"
    else
        set -- "$@" --preferred-chain "ISRG Root X1"
    fi

    if [ -n "$HOOK" ]; then
        set -- "$@" --deploy-hook "$HOOK"
    fi

    "$LEGO_BIN" "$@"
}

# --- Providers ------------------------------------------------------------
run_lego_cloudflare() {
    : "${CLOUDFLARE_DNS_API_TOKEN:?CLOUDFLARE_DNS_API_TOKEN is not set}"
    export CLOUDFLARE_DNS_API_TOKEN
    run_lego_common cloudflare
}

run_lego_godaddy() {
    : "${GODADDY_API_KEY:?GODADDY_API_KEY is not set}"
    : "${GODADDY_API_SECRET:?GODADDY_API_SECRET is not set}"
    export GODADDY_API_KEY GODADDY_API_SECRET
    run_lego_common godaddy
}

run_lego_digitalocean() {
    : "${DO_AUTH_TOKEN:?DO_AUTH_TOKEN is not set}"
    export DO_AUTH_TOKEN
    run_lego_common digitalocean
}

run_lego_dreamhost() {
    : "${DREAMHOST_API_KEY:?DREAMHOST_API_KEY is not set}"
    export DREAMHOST_API_KEY
    run_lego_common dreamhost
}

run_lego_duckdns() {
    : "${DUCKDNS_TOKEN:?DUCKDNS_TOKEN is not set}"
    export DUCKDNS_TOKEN
    run_lego_common duckdns
}


run_lego() {
    domainName="${DOMAIN_NAME}"
    wildcardDomainName="*.${DOMAIN_NAME}"
    email="${EMAIL}"

    case ${DNS_PROVIDER} in

    godaddy)
        run_lego_godaddy
        ;;

    cloudflare)
        run_lego_cloudflare
        ;;

    digitalocean)
    	run_lego_digitalocean
    	;;

    dreamhost)
        run_lego_dreamhost
        ;;

    duckdns)
    	run_lego_duckdns
    	;;

    *)
        error_exit "Unsupported DNS provider ${DNS_PROVIDER}"
        ;;
    esac
}

get_abs_filename() {
    echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
}

copy_certificate() {
    certFileName="${DOMAIN_NAME}"
    cp -f "./.lego/certificates/_.${certFileName}.key" "./${certFileName}.key"
    cp -f "./.lego/certificates/_.${certFileName}.crt" "./${certFileName}.crt"

    log "Your certificate and key are available at:"
    log "$(get_abs_filename ${certFileName}.crt)"
    log "$(get_abs_filename ${certFileName}.key)"
}

# Entrypoint

# Set default values of configuration variables.
verbose='1'
cpu=''
os=''
domainName=''
wildcardDomainName=''
email=''

check_env

set_os

set_cpu

download_lego

run_lego

copy_certificate
