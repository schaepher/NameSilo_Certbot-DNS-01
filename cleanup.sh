#!/bin/bash
# NameSilo DNS-01 Cleanup Hook – 修正 405 错误
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

source "${DIR}/config.sh"
DOMAIN="$CERTBOT_DOMAIN"
CACHE="${CACHE:-/tmp/}"
RESPONSE="${RESPONSE:-/tmp/namesilo_cleanup_response.xml}"

echo "==> Fetching DNS records..."
curl -s "https://www.namesilo.com/api/dnsListRecords?version=1&type=xml&key=$APIKEY&domain=$DOMAIN" \
     -o "${CACHE}${DOMAIN}_cleanup.xml"

if grep -q "<host>_acme-challenge</host>" "${CACHE}${DOMAIN}_cleanup.xml"; then
    echo "==> Found _acme-challenge record, deleting..."
    RECORD_ID=$(grep -B5 "<host>_acme-challenge</host>" "${CACHE}${DOMAIN}_cleanup.xml" \
        | grep "<type>TXT</type>" -B10 | grep "<record_id>" | head -1 \
        | sed 's/.*<record_id>\(.*\)<\/record_id>.*/\1/')

    if [ -z "$RECORD_ID" ]; then
        echo "ERROR: Cannot find record_id"
        exit 1
    fi

    # 关键：使用 -G 强制 GET 请求
    curl -s -G "https://www.namesilo.com/api/dnsDeleteRecord" \
        --data-urlencode "version=1" \
        --data-urlencode "type=xml" \
        --data-urlencode "key=$APIKEY" \
        --data-urlencode "domain=$DOMAIN" \
        --data-urlencode "rrid=$RECORD_ID" \
        -o "$RESPONSE"

    CODE=$(xmllint --xpath "//namesilo/reply/code/text()" "$RESPONSE" 2>/dev/null || echo "unknown")
    if [ "$CODE" == "300" ]; then
        echo "==> Record deleted successfully."
    else
        DETAIL=$(xmllint --xpath "//namesilo/reply/detail/text()" "$RESPONSE" 2>/dev/null || echo "")
        echo "ERROR: Deletion failed (code $CODE) $DETAIL"
        exit 1
    fi
else
    echo "==> No _acme-challenge record found."
fi
rm -f "${CACHE}${DOMAIN}_cleanup.xml" "$RESPONSE"
