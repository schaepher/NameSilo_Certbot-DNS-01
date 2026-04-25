#!/bin/bash
# =============================================================================
# NameSilo DNS-01 Hook for Certbot (Fixed & Cleaned)
#  解决近期因 API host 字段格式变化导致的匹配失败
#  移除强制等待，改用 certbot --dns-propagation-seconds 控制传播时间
#  增加 xmllint 兼容性回退逻辑
# =============================================================================

set -euo pipefail

# --- 定位脚本所在目录（用于加载 config.sh） ---
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

# --- 加载配置文件 ---
if [ -f "${DIR}/config.sh" ]; then
    source "${DIR}/config.sh"
else
    echo "ERROR: config.sh not found in ${DIR}"
    echo "  It must define at least: APIKEY=\"your-namesilo-api-key\""
    exit 1
fi

# --- 可选路径设置（若 config.sh 未定义则使用默认值） ---
CACHE="${CACHE:-/tmp/}"
RESPONSE="${RESPONSE:-/tmp/namesilo_response.xml}"

# Certbot 注入的环境变量
DOMAIN="$CERTBOT_DOMAIN"
VALIDATION="$CERTBOT_VALIDATION"

echo "==> Processing DNS challenge for domain: $DOMAIN"

# --- 获取当前所有 DNS 记录 ---
echo "==> Fetching current DNS records..."
curl -s "https://www.namesilo.com/api/dnsListRecords?version=1&type=xml&key=$APIKEY&domain=$DOMAIN" \
     -o "${CACHE}${DOMAIN}.xml"
if [ ! -s "${CACHE}${DOMAIN}.xml" ]; then
    echo "ERROR: Failed to retrieve DNS records from NameSilo"
    exit 1
fi

# --- 判断是否已存在 _acme-challenge TXT 记录 ---
# 注意：API 返回的 <host> 仅为相对域名，不再包含主域名
if grep -q "<host>_acme-challenge</host>" "${CACHE}${DOMAIN}.xml"; then
    echo "==> Existing _acme-challenge record found, will UPDATE it."

    # --- 提取记录 ID ---
    # 优先使用 xmllint，若失败则回退到 grep 解析
    RECORD_ID=$(xmllint --xpath \
        "//namesilo/reply/resource_record[host='_acme-challenge' and type='TXT']/record_id/text()" \
        "${CACHE}${DOMAIN}.xml" 2>/dev/null || true)

    if [ -z "$RECORD_ID" ]; then
        # 回退方案：针对不支持 --xpath 的老版本 xmllint
        RECORD_ID=$(grep -B5 "<host>_acme-challenge</host>" "${CACHE}${DOMAIN}.xml" \
                    | grep "<type>TXT</type>" -B10 \
                    | grep "<record_id>" \
                    | head -1 \
                    | sed 's/.*<record_id>\(.*\)<\/record_id>.*/\1/')
    fi

    if [ -z "$RECORD_ID" ]; then
        echo "ERROR: Could not find record_id for _acme-challenge TXT record"
        exit 1
    fi
    echo "     Record ID: $RECORD_ID"

    # --- 更新记录 ---
    echo "==> Updating DNS record with validation value..."
    curl -s "https://www.namesilo.com/api/dnsUpdateRecord?version=1&type=xml&key=$APIKEY&domain=$DOMAIN&rrid=$RECORD_ID&rrhost=_acme-challenge&rrvalue=$VALIDATION&rrttl=3600" \
         -o "$RESPONSE"

else
    echo "==> No existing _acme-challenge record found, will ADD new record."

    # --- 添加新记录 ---
    echo "==> Adding DNS TXT record..."
    curl -s "https://www.namesilo.com/api/dnsAddRecord?version=1&type=xml&key=$APIKEY&domain=$DOMAIN&rrtype=TXT&rrhost=_acme-challenge&rrvalue=$VALIDATION&rrttl=3600" \
         -o "$RESPONSE"
fi

# --- 统一处理响应 ---
RESPONSE_CODE=$(xmllint --xpath "//namesilo/reply/code/text()" "$RESPONSE" 2>/dev/null || echo "unknown")
RESPONSE_DETAIL=$(xmllint --xpath "//namesilo/reply/detail/text()" "$RESPONSE" 2>/dev/null || echo "unknown")

case "$RESPONSE_CODE" in
    300)
        echo "==> SUCCESS: DNS record updated/added."
        echo "    Please use certbot with --dns-propagation-seconds 900 (or similar) to allow"
        echo "    for NameSilo's up to 15‑minute propagation delay, instead of sleeping here."
        ;;
    280)
        echo "ERROR: Operation failed. Reason: $RESPONSE_DETAIL"
        exit 1
        ;;
    *)
        echo "ERROR: NameSilo returned unexpected code: $RESPONSE_CODE"
        echo "       Detail: $RESPONSE_DETAIL"
        exit 1
        ;;
esac

exit 0
