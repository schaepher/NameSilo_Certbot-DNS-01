#!/bin/bash
# =============================================================================
# NameSilo DNS-01 Auth Hook for Certbot
#  修复 _acme-challenge 匹配 + for 循环等待 DNS 传播
# =============================================================================
set -euo pipefail

# --- 定位脚本所在目录 ---
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

# --- 加载配置 ---
if [ -f "${DIR}/config.sh" ]; then
    source "${DIR}/config.sh"
else
    echo "ERROR: config.sh not found in ${DIR}"
    exit 1
fi

CACHE="${CACHE:-/tmp/}"
RESPONSE="${RESPONSE:-/tmp/namesilo_response.xml}"

DOMAIN="$CERTBOT_DOMAIN"
VALIDATION="$CERTBOT_VALIDATION"

echo "==> Processing DNS challenge for: $DOMAIN"

# --- 1. 获取当前记录 ---
curl -s "https://www.namesilo.com/api/dnsListRecords?version=1&type=xml&key=$APIKEY&domain=$DOMAIN" \
     -o "${CACHE}${DOMAIN}.xml"

# --- 2. 判断是否已有 _acme-challenge TXT 记录 ---
if grep -q "<host>_acme-challenge</host>" "${CACHE}${DOMAIN}.xml"; then
    echo "==> Updating existing _acme-challenge TXT record..."

    # 提取记录 ID（回退到 grep 以防 xmllint 不可用）
    RECORD_ID=$(xmllint --xpath \
        "//namesilo/reply/resource_record[host='_acme-challenge' and type='TXT']/record_id/text()" \
        "${CACHE}${DOMAIN}.xml" 2>/dev/null || true)
    if [ -z "$RECORD_ID" ]; then
        RECORD_ID=$(grep -B5 "<host>_acme-challenge</host>" "${CACHE}${DOMAIN}.xml" \
                    | grep "<type>TXT</type>" -B10 \
                    | grep "<record_id>" | head -1 \
                    | sed 's/.*<record_id>\(.*\)<\/record_id>.*/\1/')
    fi

    if [ -z "$RECORD_ID" ]; then
        echo "ERROR: Could not find record_id"
        exit 1
    fi
    echo "     Record ID: $RECORD_ID"

    # 更新记录（强制 GET 请求，防止 405 错误）
    curl -s -G "https://www.namesilo.com/api/dnsUpdateRecord" \
        --data-urlencode "version=1" \
        --data-urlencode "type=xml" \
        --data-urlencode "key=$APIKEY" \
        --data-urlencode "domain=$DOMAIN" \
        --data-urlencode "rrid=$RECORD_ID" \
        --data-urlencode "rrhost=_acme-challenge" \
        --data-urlencode "rrvalue=$VALIDATION" \
        --data-urlencode "rrttl=3600" \
        -o "$RESPONSE"

else
    echo "==> Adding new _acme-challenge TXT record..."

    curl -s -G "https://www.namesilo.com/api/dnsAddRecord" \
        --data-urlencode "version=1" \
        --data-urlencode "type=xml" \
        --data-urlencode "key=$APIKEY" \
        --data-urlencode "domain=$DOMAIN" \
        --data-urlencode "rrtype=TXT" \
        --data-urlencode "rrhost=_acme-challenge" \
        --data-urlencode "rrvalue=$VALIDATION" \
        --data-urlencode "rrttl=3600" \
        -o "$RESPONSE"
fi

# --- 3. 检查 API 返回 ---
RESPONSE_CODE=$(xmllint --xpath "//namesilo/reply/code/text()" "$RESPONSE" 2>/dev/null || echo "unknown")
RESPONSE_DETAIL=$(xmllint --xpath "//namesilo/reply/detail/text()" "$RESPONSE" 2>/dev/null || echo "unknown")

case "$RESPONSE_CODE" in
    300)
        echo "==> DNS record updated/added successfully."
        ;;
    280)
        echo "ERROR: Operation failed. Reason: $RESPONSE_DETAIL"
        exit 1
        ;;
    *)
        echo "ERROR: NameSilo returned code: $RESPONSE_CODE ($RESPONSE_DETAIL)"
        exit 1
        ;;
esac

# --- 4. 等待 DNS 传播（16 分钟，对应 NameSilo 15 分钟同步周期） ---
echo "==> Waiting 16 minutes for DNS propagation (NameSilo publishes every 15 min)..."
for ((i=1; i<=16; i++)); do
    echo "    Minute $i of 16..."
    sleep 60
done
echo "==> Propagation wait finished, returning to certbot."

exit 0
