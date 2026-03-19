echo ""
echo -e "\033[32m==================MosDNS 规则数据更新脚本=============\033[0m"
echo ""

set -e

# 定义颜色变量
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 日志输出函数
log() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${RESET}"
}

# 错误退出函数
exit_with_error() {
    log "$RED" "$1"
    exit 1
}

# 核心目录定义（仅保留 MosDNS 相关）
WORKDIR="/tmp/opnsense_update"
BIN_DIR="/usr/local/bin"
IPS="/usr/local/etc/mosdns/ips"
DOMAINS="/usr/local/etc/mosdns/domains"

# 创建临时工作目录（确保目录存在）
mkdir -p "$WORKDIR" "$IPS" "$DOMAINS" || exit_with_error "核心目录创建失败！"
cd "$WORKDIR" || exit_with_error "无法进入工作目录 $WORKDIR"

# 文件下载函数（带重试机制）
download() {
    local url="$1"
    local output="$2"
    local retries=3
    local count=0
    while [ $count -lt $retries ]; do
        curl -L --connect-timeout 10 --max-time 60 -A "Mozilla/5.0 (compatible; UpdateScript/1.0)" -o "$output" "$url" && break
        count=$((count + 1))
        log "$YELLOW" "下载失败，重试 $count/$retries: $url"
        sleep 2
    done
    if [ ! -s "$output" ]; then
        exit_with_error "下载失败或文件为空：$url"
    fi
}

# 检查 MosDNS 是否安装（可选，提示作用）
get_current_version_mosdns() {
    [ -x "$BIN_DIR/mosdns" ] && "$BIN_DIR/mosdns" -version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "未安装"
}

# 输出当前 MosDNS 版本（便于确认）
log "$YELLOW" "当前 MosDNS 版本：$(get_current_version_mosdns)"
echo ""

# 下载 MosDNS 规则数据
log "$YELLOW" "正在更新 MosDNS GeoIP/域名规则..."
download "https://ispip.clang.cn/all_cn.txt" "$WORKDIR/all_cn.txt"
download "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/direct-list.txt" "$WORKDIR/direct-list.txt"
download "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/proxy-list.txt" "$WORKDIR/proxy-list.txt"
download "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/gfw.txt" "$WORKDIR/gfw.txt"

# 复制规则文件到 MosDNS 配置目录
cp -f "$WORKDIR/all_cn.txt" "$IPS/" || log "$RED" "复制 all_cn.txt 失败！"
cp -f "$WORKDIR/direct-list.txt" "$DOMAINS/" || log "$RED" "复制 direct-list.txt 失败！"
cp -f "$WORKDIR/proxy-list.txt" "$DOMAINS/" || log "$RED" "复制 proxy-list.txt 失败！"
cp -f "$WORKDIR/gfw.txt" "$DOMAINS/" || log "$RED" "复制 gfw.txt 失败！"

# 清理临时目录
rm -rf "$WORKDIR"

# 重启 MosDNS 服务（规则更新后生效）
if [ -x "$BIN_DIR/mosdns" ]; then
    log "$YELLOW" "重启 MosDNS 服务使规则生效..."
    service mosdns restart >/dev/null 2>&1 || log "$RED" "MosDNS 服务重启失败（请手动重启）"
else
    log "$YELLOW" "未检测到 MosDNS 可执行文件，跳过服务重启"
fi

# 完成提示
log "$GREEN" "MosDNS 规则数据更新完成！"
echo ""