#!/bin/sh
# MosDNS 规则自动升级脚本 (OPNsense 专用)
# 修复：ash语法兼容（移除函数外local）+ 变量解析 + 空值校验

# ==================== 全局配置区 (适配ash) ====================
# 核心目录
MOSDNS_WORK_DIR="/usr/local/etc/mosdns"
RULE_DIR="${MOSDNS_WORK_DIR}/rule"
IPS_DIR="${MOSDNS_WORK_DIR}/ips"
DOMAINS_DIR="${MOSDNS_WORK_DIR}/domains"
TMP_DIR="/tmp/easymosdns"
LOG_FILE="/var/log/mosdns_rule_update.log"

# 网络配置
GITHUB_PROXY="https://raw.githubusercontent.com"
CURL_TIMEOUT=15
CURL_RETRY=3

# 功能开关
BACKUP_ENABLE="yes"
RESTART_MOSDNS="yes"

# 颜色定义（适配ash）
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
RESET="\033[0m"

# 初始化计数变量（关键：ash中必须提前赋值）
FAIL_COUNT=0
SUCCESS_COUNT=0

# ==================== 规则列表 (单行写法，确保|分割正确) ====================
RULE_LIST="CN-ip-cidr.txt|Teacher-c/clash/main/CN-ip-cidr.txt Akamai_ipv4.txt|Teacher-c/clash/main/data/Akamai_ipv4.txt akamai_domain_list.txt|Journalist-HK/Rules/main/akamai_domain_list.txt block_list.txt|Journalist-HK/Rules/main/block_list.txt cachefly_ipv4.txt|Journalist-HK/Rules/main/cachefly_ipv4.txt cdn77_ipv4.txt|Journalist-HK/Rules/main/cdn77_ipv4.txt cdn77_ipv6.txt|Journalist-HK/Rules/main/cdn77_ipv6.txt china_domain_list_mini.txt|Journalist-HK/Rules/main/china_domain_list_mini.txt cloudfront.txt|Journalist-HK/Rules/main/cloudfront.txt cloudfront_ipv6.txt|Journalist-HK/Rules/main/cloudfront_ipv6.txt custom_list.txt|Journalist-HK/Rules/main/custom_list.txt gfw_ip_list.txt|Journalist-HK/Rules/main/gfw_ip_list.txt grey_list_js.txt|Journalist-HK/Rules/main/grey_list_js.txt grey_list.txt|Journalist-HK/Rules/main/grey_list.txt hosts_akamai.txt|Journalist-HK/Rules/main/hosts_akamai.txt hosts_fastly.txt|Journalist-HK/Rules/main/hosts_fastly.txt jp_dns_list.txt|Journalist-HK/Rules/main/jp_dns_list.txt original_domain_list.txt|Journalist-HK/Rules/main/original_domain_list.txt ipv6_domain_list.txt|Journalist-HK/Rules/main/ipv6_domain_list.txt private.txt|Journalist-HK/Rules/main/private.txt redirect.txt|Journalist-HK/Rules/main/redirect.txt sucuri_ipv4.txt|Journalist-HK/Rules/main/sucuri_ipv4.txt us_dns_list.txt|Journalist-HK/Rules/main/us_dns_list.txt white_list.txt|Journalist-HK/Rules/main/white_list.txt facebook.txt|Loyalsoldier/geoip/release/text/facebook.txt fastly.txt|Loyalsoldier/geoip/release/text/fastly.txt telegram.txt|Loyalsoldier/geoip/release/text/telegram.txt twitter.txt|Loyalsoldier/geoip/release/text/twitter.txt gfw.txt|Loyalsoldier/v2ray-rules-dat/release/gfw.txt greatfire.txt|Loyalsoldier/v2ray-rules-dat/release/greatfire.txt ad_domain_list.txt|pmkol/easymosdns/rules/ad_domain_list.txt cdn_domain_list.txt|pmkol/easymosdns/rules/cdn_domain_list.txt china_domain_list.txt|pmkol/easymosdns/rules/china_domain_list.txt china_ip_list.txt|pmkol/easymosdns/rules/china_ip_list.txt ip.txt|XIU2/CloudflareSpeedTest/master/ip.txt ipv6.txt|XIU2/CloudflareSpeedTest/master/ipv6.txt"

EXTRA_RULES="all_cn.txt|https://ispip.clang.cn/all_cn.txt direct-list.txt|https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/direct-list.txt proxy-list.txt|https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/proxy-list.txt gfw-extra.txt|https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/gfw.txt"

# ==================== 工具函数 (所有local仅在函数内使用) ====================
log() {
    local LEVEL=$1
    local COLOR=$2
    local MSG=$3
    local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 写入日志文件（无颜色）
    echo "[${TIMESTAMP}] [${LEVEL}] ${MSG}" >> "${LOG_FILE}"
    # 终端输出（带颜色）
    echo -e "${COLOR}[${TIMESTAMP}] [${LEVEL}] ${MSG}${RESET}"
}

error_exit() {
    log "ERROR" "${RED}" "$1"
    [ -d "${TMP_DIR}" ] && rm -rf "${TMP_DIR}"
    exit 1
}

download_file() {
    local URL=$1
    local OUTPUT=$2
    local FILENAME=$3

    # 空值校验（关键：避免curl参数为空）
    if [ -z "${URL}" ] || [ -z "${OUTPUT}" ] || [ -z "${FILENAME}" ]; then
        log "ERROR" "${RED}" "下载参数为空：FILENAME=${FILENAME} URL=${URL}"
        return 1
    fi

    log "INFO" "${BLUE}" "正在下载: ${FILENAME}"
    if curl -L --fail --silent --show-error \
        --connect-timeout "${CURL_TIMEOUT}" \
        --retry "${CURL_RETRY}" \
        -A "Mozilla/5.0 (compatible; MosDNSUpdate/1.0)" \
        -o "${OUTPUT}" "${URL}"; then
        
        if [ -s "${OUTPUT}" ]; then
            log "INFO" "${GREEN}" "下载成功: ${FILENAME}"
            return 0
        else
            log "ERROR" "${RED}" "文件为空: ${FILENAME}"
            rm -f "${OUTPUT}"
            return 1
        fi
    else
        log "ERROR" "${RED}" "下载失败: ${FILENAME} (URL: ${URL})"
        return 1
    fi
}

get_mosdns_version() {
    if [ -x "/usr/local/bin/mosdns" ]; then
        /usr/local/bin/mosdns version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "未知版本"
    else
        echo "未安装"
    fi
}

# ==================== 主逻辑 (移除所有local，适配ash) ====================
clear
echo -e "${BLUE}================== MosDNS 规则全量更新脚本 ==================${RESET}"
echo ""

# 初始化目录
log "INFO" "${BLUE}" "初始化工作目录..."
mkdir -p "${TMP_DIR}" "${RULE_DIR}" "${IPS_DIR}" "${DOMAINS_DIR}" || error_exit "核心目录创建失败！"

# 输出当前版本
log "INFO" "${YELLOW}" "当前 MosDNS 版本：$(get_mosdns_version)"
echo ""

# 备份旧规则
if [ "${BACKUP_ENABLE}" = "yes" ]; then
    BACKUP_DIR="${MOSDNS_WORK_DIR}/rule_backup_$(date +%Y%m%d_%H%M%S)"
    if [ -d "${RULE_DIR}" ] && [ "$(ls -A "${RULE_DIR}")" ]; then
        cp -rf "${RULE_DIR}" "${BACKUP_DIR}" || log "WARNING" "${YELLOW}" "备份旧规则失败，但继续执行更新"
        log "INFO" "${GREEN}" "旧规则已备份至: ${BACKUP_DIR}"
    fi
fi

# 第一步：下载GitHub规则列表
log "INFO" "${BLUE}" "========== 开始下载 GitHub 规则文件 =========="
for RULE in ${RULE_LIST}; do
    # 分割规则（确保|分割正确，ash中cut兼容）
    FILENAME=$(echo "${RULE}" | cut -d'|' -f1)
    REPO_PATH=$(echo "${RULE}" | cut -d'|' -f2)
    DOWNLOAD_URL="${GITHUB_PROXY}/${REPO_PATH}"
    TMP_FILE="${TMP_DIR}/${FILENAME}"

    if download_file "${DOWNLOAD_URL}" "${TMP_FILE}" "${FILENAME}"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

# 第二步：下载额外补充规则
log "INFO" "${BLUE}" "========== 开始下载 额外GeoIP/域名规则 =========="
for EXTRA in ${EXTRA_RULES}; do
    FILENAME=$(echo "${EXTRA}" | cut -d'|' -f1)
    URL=$(echo "${EXTRA}" | cut -d'|' -f2)
    TMP_FILE="${TMP_DIR}/${FILENAME}"

    if download_file "${URL}" "${TMP_FILE}" "${FILENAME}"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        # 按类型复制到对应目录
        case "${FILENAME}" in
            all_cn.txt)
                cp -f "${TMP_FILE}" "${IPS_DIR}/" || log "WARNING" "${YELLOW}" "复制 ${FILENAME} 到 ${IPS_DIR} 失败"
                ;;
            direct-list.txt|proxy-list.txt|gfw-extra.txt)
                cp -f "${TMP_FILE}" "${DOMAINS_DIR}/" || log "WARNING" "${YELLOW}" "复制 ${FILENAME} 到 ${DOMAINS_DIR} 失败"
                ;;
            *)
                cp -f "${TMP_FILE}" "${RULE_DIR}/" || log "WARNING" "${YELLOW}" "复制 ${FILENAME} 到 ${RULE_DIR} 失败"
                ;;
        esac
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

# 第三步：复制GitHub规则到目标目录
log "INFO" "${BLUE}" "========== 替换规则文件 =========="
if [ -n "$(ls -A "${TMP_DIR}"/*.txt 2>/dev/null)" ]; then
    cp -rf "${TMP_DIR}"/*.txt "${RULE_DIR}/" || log "WARNING" "${YELLOW}" "部分GitHub规则文件替换失败"
else
    log "WARNING" "${YELLOW}" "临时目录无规则文件，跳过替换"
fi

# 第四步：重启MosDNS服务
if [ "${RESTART_MOSDNS}" = "yes" ]; then
    log "INFO" "${YELLOW}" "重启 MosDNS 服务使规则生效..."
    if service mosdns restart >/dev/null 2>&1; then
        log "INFO" "${GREEN}" "MosDNS 重启成功"
    else
        log "WARNING" "${RED}" "MosDNS 重启失败，请手动执行: service mosdns restart"
    fi
fi

# 清理临时文件
rm -rf "${TMP_DIR}"

# 输出最终统计
echo ""
log "INFO" "${BLUE}" "========== 更新完成 统计 =========="
log "INFO" "${GREEN}" "成功下载: ${SUCCESS_COUNT} 个文件"
log "INFO" "${RED}" "失败下载: ${FAIL_COUNT} 个文件"
log "INFO" "${GREEN}" "MosDNS 规则全量更新完成！"
echo -e "${BLUE}=================================================${RESET}"

exit 0