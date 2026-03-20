#!/bin/sh
# MosDNS 规则自动升级脚本 (OPNsense 专用)
# 修复：适配ash/sh语法、移除bash特性、统一换行符

# ==================== 配置区 (可按需修改) ====================
MOSDNS_WORK_DIR="/usr/local/etc/mosdns"
RULE_DIR="${MOSDNS_WORK_DIR}/rule"
TMP_DIR="/tmp/easymosdns"
LOG_FILE="/var/log/mosdns_rule_update.log"
# 修复后的代理URL（核心！原URL重复https://导致下载失败）
GITHUB_PROXY="https://github.boki.moe/raw.githubusercontent.com"
BACKUP_ENABLE="yes"
RESTART_MOSDNS="yes"

# ==================== 规则列表 (适配ash的单行数组写法) ====================
# 格式："文件名|仓库路径"（所有元素写在一行，用空格分隔）
RULE_LIST="akamai_domain_list.txt|Journalist-HK/Rules/main/akamai_domain_list.txt block_list.txt|Journalist-HK/Rules/main/block_list.txt cachefly_ipv4.txt|Journalist-HK/Rules/main/cachefly_ipv4.txt cdn77_ipv4.txt|Journalist-HK/Rules/main/cdn77_ipv4.txt cdn77_ipv6.txt|Journalist-HK/Rules/main/cdn77_ipv6.txt china_domain_list_mini.txt|Journalist-HK/Rules/main/china_domain_list_mini.txt cloudfront.txt|Journalist-HK/Rules/main/cloudfront.txt cloudfront_ipv6.txt|Journalist-HK/Rules/main/cloudfront_ipv6.txt custom_list.txt|Journalist-HK/Rules/main/custom_list.txt gfw_ip_list.txt|Journalist-HK/Rules/main/gfw_ip_list.txt grey_list_js.txt|Journalist-HK/Rules/main/grey_list_js.txt grey_list.txt|Journalist-HK/Rules/main/grey_list.txt hosts_akamai.txt|Journalist-HK/Rules/main/hosts_akamai.txt hosts_fastly.txt|Journalist-HK/Rules/main/hosts_fastly.txt jp_dns_list.txt|Journalist-HK/Rules/main/jp_dns_list.txt original_domain_list.txt|Journalist-HK/Rules/main/original_domain_list.txt ipv6_domain_list.txt|Journalist-HK/Rules/main/ipv6_domain_list.txt private.txt|Journalist-HK/Rules/main/private.txt redirect.txt|Journalist-HK/Rules/main/redirect.txt sucuri_ipv4.txt|Journalist-HK/Rules/main/sucuri_ipv4.txt us_dns_list.txt|Journalist-HK/Rules/main/us_dns_list.txt white_list.txt|Journalist-HK/Rules/main/white_list.txt facebook.txt|Loyalsoldier/geoip/release/text/facebook.txt fastly.txt|Loyalsoldier/geoip/release/text/fastly.txt telegram.txt|Loyalsoldier/geoip/release/text/telegram.txt twitter.txt|Loyalsoldier/geoip/release/text/twitter.txt gfw.txt|Loyalsoldier/v2ray-rules-dat/release/gfw.txt greatfire.txt|Loyalsoldier/v2ray-rules-dat/release/greatfire.txt ad_domain_list.txt|pmkol/easymosdns/rules/ad_domain_list.txt cdn_domain_list.txt|pmkol/easymosdns/rules/cdn_domain_list.txt china_domain_list.txt|pmkol/easymosdns/rules/china_domain_list.txt china_ip_list.txt|pmkol/easymosdns/rules/china_ip_list.txt ip.txt|XIU2/CloudflareSpeedTest/master/ip.txt ipv6.txt|XIU2/CloudflareSpeedTest/master/ipv6.txt"

# ==================== 工具函数 ====================
log() {
    LEVEL=$1
    MSG=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${LEVEL}] ${MSG}" | tee -a "${LOG_FILE}"
}

error_exit() {
    log "ERROR" "$1"
    [ -d "${TMP_DIR}" ] && rm -rf "${TMP_DIR}"
    exit 1
}

# ==================== 主逻辑 ====================
log "INFO" "========== 开始更新 MosDNS 规则 =========="
mkdir -p "${TMP_DIR}" "${RULE_DIR}" || error_exit "创建目录失败"

# 备份旧规则
if [ "${BACKUP_ENABLE}" = "yes" ]; then
    BACKUP_DIR="${MOSDNS_WORK_DIR}/rule_backup_$(date +%Y%m%d_%H%M%S)"
    if [ -d "${RULE_DIR}" ] && [ "$(ls -A "${RULE_DIR}")" ]; then
        cp -rf "${RULE_DIR}" "${BACKUP_DIR}" || log "WARNING" "备份旧规则失败，但继续执行更新"
        log "INFO" "旧规则已备份至: ${BACKUP_DIR}"
    fi
fi

# 批量下载规则（适配ash的循环写法）
log "INFO" "开始下载规则文件..."
FAIL_COUNT=0
# 将RULE_LIST按空格拆分为单个规则，循环处理
for RULE in ${RULE_LIST}; do
    FILENAME=$(echo "${RULE}" | cut -d'|' -f1)
    REPO_PATH=$(echo "${RULE}" | cut -d'|' -f2)
    DOWNLOAD_URL="${GITHUB_PROXY}/${REPO_PATH}"
    TMP_FILE="${TMP_DIR}/${FILENAME}"

    log "INFO" "正在下载: ${FILENAME}"
    # curl参数适配ash，增加重试机制
    if ! curl --fail --silent --show-error --connect-timeout 10 --retry 2 -o "${TMP_FILE}" "${DOWNLOAD_URL}"; then
        log "ERROR" "下载失败: ${FILENAME}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    # 检查空文件
    if [ ! -s "${TMP_FILE}" ]; then
        log "ERROR" "文件为空: ${FILENAME}"
        rm -f "${TMP_FILE}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
done

# 检查下载结果
if [ "${FAIL_COUNT}" -gt 0 ]; then
    error_exit "共${FAIL_COUNT}个文件下载失败，终止更新 (日志: ${LOG_FILE})"
fi

# 替换规则文件
log "INFO" "所有文件下载成功，替换规则文件..."
cp -rf "${TMP_DIR}"/*.txt "${RULE_DIR}/" || error_exit "替换规则文件失败"

# 重启MosDNS
if [ "${RESTART_MOSDNS}" = "yes" ]; then
    log "INFO" "重启 MosDNS 服务..."
    service mosdns restart >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log "INFO" "MosDNS 重启成功"
    else
        log "WARNING" "MosDNS 重启失败，请手动重启"
    fi
fi

# 清理临时文件
rm -rf "${TMP_DIR}"
log "INFO" "========== MosDNS 规则更新完成 =========="
echo "update successful"
exit 0