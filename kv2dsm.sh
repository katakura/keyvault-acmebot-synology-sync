#!/bin/bash
# kv2dsm.sh - Key Vault の証明書(PFX)を取得して、更新されていれば DSM に登録する
#   使い方: kv2dsm.sh [--dry-run]   (FORCE=1 で変更なしでも登録)
#   --dry-run: Azure 取得・検証・DSM ログイン・証明書の特定まで行い、登録はしない
set -euo pipefail

BASE_DIR="${KV2DSM_DIR:-/var/services/homes/fsadmin/scripts}"
CONF="$BASE_DIR/kv2dsm.conf"
STATE="$BASE_DIR/last_version"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# shellcheck disable=SC1090
. "$CONF"
: "${TENANT:?}" "${CLIENT_ID:?}" "${CLIENT_SECRET:?}" "${VAULT:?}" "${SECRET_NAME:?}"
: "${EXPECT_DOMAIN:?}" "${SYNO_USERNAME:?}" "${SYNO_PASSWORD:?}" "${SYNO_CERT_DESC:?}"
SYNO_BASE="${SYNO_BASE:-http://localhost:5000}"

WORK=$(mktemp -d)
chmod 700 "$WORK"
sid=""
AUTH_PATH="entry.cgi"
AUTH_VER="7"

cleanup() {
  if [ -n "$sid" ]; then
    curl -fsS -G "$SYNO_BASE/webapi/$AUTH_PATH" \
      --data-urlencode "api=SYNO.API.Auth" --data-urlencode "version=$AUTH_VER" \
      --data-urlencode "method=logout" --data-urlencode "_sid=$sid" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

log() { echo "$(date '+%F %T') $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# 1) Entra ID でトークン取得
TOKEN=$(curl -fsS -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  --data-urlencode "scope=https://vault.azure.net/.default" \
  --data-urlencode "grant_type=client_credentials" | jq -r '.access_token // empty')
[ -n "$TOKEN" ] || die "Entra ID のトークンが取れませんでした"

# 2) Key Vault からシークレット取得(最新バージョン)
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "https://$VAULT.vault.azure.net/secrets/$SECRET_NAME?api-version=7.4" > "$WORK/secret.json"
VERSION=$(jq -r '.id | split("/") | last' "$WORK/secret.json")
CTYPE=$(jq -r '.contentType // empty' "$WORK/secret.json")
[ "$CTYPE" = "application/x-pkcs12" ] || die "想定外の contentType: $CTYPE"
log "Key Vault の最新バージョン: $VERSION"

LAST=$(cat "$STATE" 2>/dev/null || true)
if [ "$VERSION" = "$LAST" ] && [ "${FORCE:-0}" != "1" ] && [ "$DRY_RUN" != "1" ]; then
  log "更新なし。終了します"
  exit 0
fi

# 3) PFX を PEM に分解 (Key Vault の PFX はパスワード無し)
jq -r '.value' "$WORK/secret.json" | base64 -d > "$WORK/cert.pfx"
openssl pkcs12 -in "$WORK/cert.pfx" -passin pass: -nokeys -clcerts \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "$WORK/cert.pem"
openssl pkcs12 -in "$WORK/cert.pfx" -passin pass: -nokeys -cacerts \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "$WORK/chain.pem"
openssl pkcs12 -in "$WORK/cert.pfx" -passin pass: -nocerts -nodes \
  | sed -n '/-----BEGIN .*PRIVATE KEY-----/,/-----END .*PRIVATE KEY-----/p' > "$WORK/key.pem"
chmod 600 "$WORK/key.pem"
[ -s "$WORK/cert.pem" ] && [ -s "$WORK/chain.pem" ] && [ -s "$WORK/key.pem" ] || die "PEM の分解に失敗"

# 4) 登録前の検証(期限・SAN・証明書と秘密鍵の対応)
openssl x509 -in "$WORK/cert.pem" -noout -checkend 86400 >/dev/null || die "証明書が期限切れ(または24時間以内)"
openssl x509 -in "$WORK/cert.pem" -noout -ext subjectAltName | grep -q "DNS:$EXPECT_DOMAIN" \
  || die "SAN に $EXPECT_DOMAIN がありません"
PUB_CERT=$(openssl x509 -in "$WORK/cert.pem" -noout -pubkey | openssl sha256)
PUB_KEY=$(openssl pkey -in "$WORK/key.pem" -pubout | openssl sha256)
[ "$PUB_CERT" = "$PUB_KEY" ] || die "証明書と秘密鍵が対応していません"
log "検証OK: $(openssl x509 -in "$WORK/cert.pem" -noout -subject -enddate | tr '\n' ' ')"

# 5) DSM にログイン
INFO=$(curl -fsS "$SYNO_BASE/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth")
AUTH_PATH=$(echo "$INFO" | jq -r '.data["SYNO.API.Auth"].path')
AUTH_VER=$(echo "$INFO" | jq -r '.data["SYNO.API.Auth"].maxVersion')
LOGIN=$(curl -fsS -X POST "$SYNO_BASE/webapi/$AUTH_PATH" \
  --data-urlencode "api=SYNO.API.Auth" --data-urlencode "version=$AUTH_VER" \
  --data-urlencode "method=login" --data-urlencode "format=sid" \
  --data-urlencode "enable_syno_token=yes" \
  --data-urlencode "account=$SYNO_USERNAME" --data-urlencode "passwd=$SYNO_PASSWORD")
[ "$(echo "$LOGIN" | jq -r '.success')" = "true" ] \
  || die "DSM ログイン失敗: $(echo "$LOGIN" | jq -c '.error')"
sid=$(echo "$LOGIN" | jq -r '.data.sid')
SYNOTOKEN=$(echo "$LOGIN" | jq -r '.data.synotoken')

# 6) 置き換え対象の証明書を、DSM上の「説明」で特定
LIST=$(curl -fsS -X POST "$SYNO_BASE/webapi/entry.cgi" -H "X-SYNO-TOKEN: $SYNOTOKEN" \
  --data-urlencode "api=SYNO.Core.Certificate.CRT" --data-urlencode "method=list" \
  --data-urlencode "version=1" --data-urlencode "_sid=$sid")
CERT=$(echo "$LIST" | jq -c --arg d "$SYNO_CERT_DESC" '[.. | objects | select(.desc == $d)] | .[0] // empty')
if [ -z "$CERT" ]; then
  log "DSM 上の証明書の説明(desc)一覧:"
  echo "$LIST" | jq -r '[.. | objects | select(has("desc")) | .desc] | .[]'
  die "説明が '$SYNO_CERT_DESC' の証明書が DSM に見つかりません"
fi
CERT_ID=$(echo "$CERT" | jq -r '.id')
IS_DEFAULT=$(echo "$CERT" | jq -r '.is_default // false')
log "置き換え対象: id=$CERT_ID is_default=$IS_DEFAULT"

if [ "$DRY_RUN" = "1" ]; then
  log "--dry-run のため、登録せずに終了します"
  exit 0
fi

# 7) DSM に登録(同じ id を上書き。サービスへの割り当ては維持される)
ARGS=(-F "key=@$WORK/key.pem" -F "cert=@$WORK/cert.pem" -F "inter_cert=@$WORK/chain.pem"
      -F "id=$CERT_ID" -F "desc=$SYNO_CERT_DESC")
if [ "$IS_DEFAULT" = "true" ]; then ARGS+=(-F "as_default=true"); fi
RESP=$(curl -fsS -X POST \
  "$SYNO_BASE/webapi/entry.cgi?api=SYNO.Core.Certificate&method=import&version=1&SynoToken=$SYNOTOKEN&_sid=$sid" \
  -H "X-SYNO-TOKEN: $SYNOTOKEN" "${ARGS[@]}")
[ "$(echo "$RESP" | jq -r '.success')" = "true" ] || die "DSM への登録に失敗: $(echo "$RESP" | jq -c '.error')"

# 8) 成功したときだけ、状態ファイルを更新
echo "$VERSION" > "$STATE"
log "登録しました (version=$VERSION, restart_httpd=$(echo "$RESP" | jq -r '.data.restart_httpd // false'))"
