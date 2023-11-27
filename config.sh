#!/bin/env bash

set -e -o pipefail -u

OS=${OS:-$(uname -s)}
STALWART_BASE=${STALWART_BASE:-/opt/stalwart-mail}
## Prevent path expansion on MSYS2/MINGW environments
export MSYS2_ENV_CONV_EXCL='STALWART_BASE'
export STALWART_BASE

cd "${0%/*}"

if ! type ./stalwart-install &>/dev/null; then
  TAG=${TAG:-$(curl -s https://api.github.com/repos/stalwartlabs/mail-server/releases/latest | yq -r '.tag_name')}
  case $OS in
    Linux)
      set -x
      curl -L "https://github.com/stalwartlabs/mail-server/releases/download/$TAG/stalwart-install-x86_64-unknown-linux-gnu.tar.gz" | tar -xzvf -
      { set +x; } 2>/dev/null
      ;;
    Darwin)
      set -x
      curl -L "https://github.com/stalwartlabs/mail-server/releases/download/$TAG/stalwart-install-x86_64-apple-darwin.tar.gz" | tar -xzvf -
      { set +x; } 2>/dev/null
      ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      temp_file=$(mktemp)
      set -x
      curl -L "https://github.com/stalwartlabs/mail-server/releases/download/$TAG/stalwart-install-x86_64-pc-windows-msvc.zip" -o "$temp_file"
      unzip -o "$temp_file"
      rm -fr "$temp_file"
      { set +x; } 2>/dev/null
      ;;
    *)
      echo "Unsupported OS: $OS"
      exit 1
      ;;
  esac
fi

CONFIG_DIR=config
STALWART_CONFIG_DIR="$CONFIG_DIR/etc"

## Cleanup
rm -fr "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR"

## Run installer
./stalwart-install -c all-in-one -p "$STALWART_CONFIG_DIR/.." -d
## Fix paths in toml files
sed -i -E "s,$STALWART_CONFIG_DIR/\.\.,$STALWART_BASE," "$STALWART_CONFIG_DIR/config.toml" "$STALWART_CONFIG_DIR/common/tls.toml"
## Enable stdoud logging
sed -i -E -e 's,^([^#]),#\1,g' -e '5,8s/^#//' "$STALWART_CONFIG_DIR/common/tracing.toml"

cp examples/litestream.yaml examples/statefulset.patch.yaml "$CONFIG_DIR"

## Cleanup
rm -fr \
    "${CONFIG_DIR:?}/bin" \
    "${CONFIG_DIR:?}/logs" \
    "${CONFIG_DIR:?}/queue" \
    "${CONFIG_DIR:?}/reports" \
    "$STALWART_CONFIG_DIR/spamfilter/" \
    "$STALWART_CONFIG_DIR/certs/" \
    "$STALWART_CONFIG_DIR/directory/ldap.toml" \
    "$STALWART_CONFIG_DIR/directory/memory.toml"

SQLITE_FILES=$(
  cd "$CONFIG_DIR";
  find "data" -name '*.sqlite3' -printf '      - %f=%p\n'
)
export SQLITE_FILES

DKIM_FILES=$(
  cd "$CONFIG_DIR";
  find "etc/dkim" -type f -printf '      - %f=%p\n'
)
export DKIM_FILES

CONFIG_FILES=$(
  cd "$CONFIG_DIR";
  find etc -name '*.toml' -printf '      - %P=%p\n' | sed -E 's,/([^=]+)=,_\1=,'
)
export CONFIG_FILES

envsubst < templates/config-kustomization.yaml > "$CONFIG_DIR/kustomization.yaml"

## Generate volumeMounts patch
echo "$CONFIG_FILES" | yq --from-file templates/volume-mounts.yq > "$CONFIG_DIR/volume-mounts.patch.yaml"

## Generate ingress patch
STALWART_HOST=$(yq '.macros.host' "$STALWART_CONFIG_DIR/config.toml")
export STALWART_HOST
yq '.[0].value = env(STALWART_HOST)' examples/ingress.patch.yaml > "$CONFIG_DIR/ingress.patch.yaml"
