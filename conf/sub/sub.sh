#!/bin/sh
set -euo pipefail  # 开启严格模式，错误立即退出
# 在线订阅转换脚本 - 适配OPNsense/FreeBSD

#################### 初始化 ####################
# 脚本绝对路径（兼容OPNsense任意目录执行）
Server_Dir=$(cd "$(dirname "$(realpath "$0")")" && pwd)
[ -f "$Server_Dir/env" ] && . "$Server_Dir/env"

API_BASE="https://subconverters.com/sub"

# 目录定义
Conf_Dir="$Server_Dir/conf"
Temp_Dir="$Server_Dir/temp"
Clash_Dir="/usr/local/etc/clash"
Dashboard_Dir="${Server_Dir}/ui"
# 创建目录并检查权限
mkdir -p "$Conf_Dir" "$Temp_Dir" || { echo "错误：无法创建目录，请检查权限"; exit 1; }

# 依赖检查（OPNsense需提前安装jq/curl：pkg install jq curl openssl）
check_dependency() {
    local cmd=$1
    local name=$2
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "错误：缺少必需工具 $name，请执行：pkg install $cmd（OPNsense）"
        exit 1
    fi
}
check_dependency jq "jq（用于URL编码）"
check_dependency curl "curl（用于下载配置）"
check_dependency openssl "openssl（用于生成Secret）"

# 临时文件（注册退出钩子，确保清理）
TMP_RAW=$(mktemp "$Temp_Dir/clash_config.XXXX.yaml")
TMP_PROXIES=$(mktemp "$Temp_Dir/proxies.XXXX.txt")
TMP_FINAL=$(mktemp "$Temp_Dir/config.XXXX.yaml")
# 兼容模板文件名拼写错误（自动修正）
TEMPLATE_FILE="$Temp_Dir/template_config.yaml"
TEMPLATE_FILE_OLD="$Temp_Dir/templete_config.yaml"
if [ -f "$TEMPLATE_FILE_OLD" ] && [ ! -f "$TEMPLATE_FILE" ]; then
    echo "检测到模板文件名拼写错误，自动修正：$TEMPLATE_FILE_OLD → $TEMPLATE_FILE"
    mv "$TEMPLATE_FILE_OLD" "$TEMPLATE_FILE"
fi
# 脚本退出时清理临时文件
trap 'rm -f "$TMP_RAW" "$TMP_PROXIES" "$TMP_FINAL"' EXIT

# Clash订阅地址校验
[ -z "${CLASH_URL:-}" ] && {
    echo "错误：未设置 CLASH_URL 环境变量（示例：export CLASH_URL='你的订阅地址'）"
    exit 1
}

# 生成Secret（优先环境变量，否则随机生成）
Secret=${CLASH_SECRET:-$(openssl rand -hex 32)}

#################### 下载配置 ####################
# URL编码订阅地址
ENCODED_URL=$(printf "%s" "$CLASH_URL" | jq -s -R -r @uri)
API_URL="${API_BASE}?target=clash&url=${ENCODED_URL}&udp=true&clash.dns=true&list=false"
echo ""
echo "尝试不使用代理从：$API_URL 下载配置..."

# 下载配置并校验有效性
DOWNLOAD_SUCCESS=false
if curl -L -k -sS --retry 2 -m 15 -o "$TMP_RAW" "$API_URL"; then
    # 检查配置是否有效（非空且包含proxies）
    if [ -s "$TMP_RAW" ] && grep -q "^proxies:" "$TMP_RAW"; then
        echo "下载成功：$TMP_RAW"
        DOWNLOAD_SUCCESS=true
    else
        echo "警告：直连下载的配置无效，尝试通过代理下载..."
    fi
fi

# 代理下载（OPNsense下Clash监听7891）
if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "尝试通过 SOCKS5 代理 127.0.0.1:7891 下载配置..."
    if ! curl -L -k -sS --retry 1 -m 15 --socks5-hostname 127.0.0.1:7891 -o "$TMP_RAW" "$API_URL"; then
        echo "错误：下载失败！请检查："
        echo "  1. CLASH_URL 订阅地址是否有效"
        echo "  2. Clash 是否运行并监听 127.0.0.1:7891"
        exit 1
    fi
    # 再次校验配置
    if [ ! -s "$TMP_RAW" ] || ! grep -q "^proxies:" "$TMP_RAW"; then
        echo "错误：代理下载的配置仍无效，请检查订阅地址！"
        exit 1
    fi
    echo "下载成功：$TMP_RAW"
fi
echo ""

#################### 合成配置 ####################
# 检查模板文件
[ ! -f "$TEMPLATE_FILE" ] && {
    echo "错误：缺少模板文件：$TEMPLATE_FILE"
    exit 1
}

# 提取代理部分（仅保留proxies及之后）
sed -n '/^proxies:/,$p' "$TMP_RAW" > "$TMP_PROXIES"

# 合成配置（移除模板中重复的proxies）
echo "合成配置..."
sleep 1
grep -v "^proxies:" "$TEMPLATE_FILE" > "$TMP_FINAL"  # 避免模板已有proxies导致重复
cat "$TMP_PROXIES" >> "$TMP_FINAL"
cp -f "$TMP_FINAL" "$Conf_Dir/config.yaml" || { echo "错误：无法写入配置到 $Conf_Dir"; exit 1; }

# 设置 external-ui（适配OPNsense/FreeBSD、Linux、macOS）
OS_TYPE=$(uname -s)
echo "检测到系统类型：$OS_TYPE"
if [ "$OS_TYPE" = "Linux" ]; then
    # Linux（GNU sed）
    sed -i "s@^# external-ui:.*@external-ui: ${Dashboard_Dir}@" "$Conf_Dir/config.yaml"
elif [ "$OS_TYPE" = "Darwin" ]; then
    # macOS（BSD sed）
    sed -i '' "s@^# external-ui:.*@external-ui: ${Dashboard_Dir}@" "$Conf_Dir/config.yaml"
elif [ "$OS_TYPE" = "FreeBSD" ]; then
    # OPNsense（FreeBSD）：指定备份扩展名并自动删除
    sed -i .bak "s@^# external-ui:.*@external-ui: ${Dashboard_Dir}@" "$Conf_Dir/config.yaml"
    rm -f "${Conf_Dir}/config.yaml.bak"
fi

# 确保在 external-ui 行之后插入 secret（避免重复）
if grep -q '^external-ui:' "$Conf_Dir/config.yaml"; then
    awk -v secret="secret: ${Secret}" '
      /^external-ui:/ {
          print;
          if (!secret_inserted) {
              print secret;
              secret_inserted=1;
          }
          next
      }
      /^secret:/ { secret_inserted=1 }
      { print }
    ' "$Conf_Dir/config.yaml" > "$Conf_Dir/config.new.yaml" && mv -f "$Conf_Dir/config.new.yaml" "$Conf_Dir/config.yaml"
else
    echo "secret: ${Secret}" >> "$Conf_Dir/config.yaml"
fi
echo "合成完成!"
echo ""

#################### 应用配置并重启 ####################
# 检查Clash目录权限
if [ ! -w "$Clash_Dir" ]; then
    echo "错误：无写入权限到 $Clash_Dir，请使用sudo执行脚本"
    exit 1
fi

echo "替换配置..."
sleep 1
cp -f "$Conf_Dir/config.yaml" "$Clash_Dir/config.yaml" || { echo "错误：替换配置失败"; exit 1; }

# 重启Clash（适配OPNsense/FreeBSD的rc.d）
echo "重启服务..."
if [ "$OS_TYPE" = "FreeBSD" ]; then
    # OPNsense：优先使用rc.d重启
    if [ -f "/usr/local/etc/rc.d/clash" ]; then
        /usr/local/etc/rc.d/clash restart >/dev/null 2>&1 && echo "重启完成（rc.d）！" || echo "错误：rc.d重启Clash失败"
    else
        echo "警告：未找到Clash的rc.d脚本，尝试service命令..."
        service clash restart >/dev/null 2>&1 && echo "重启完成（service）！" || echo "错误：重启Clash失败，请手动重启"
    fi
elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet clash; then
    # Linux：systemctl
    systemctl restart clash >/dev/null 2>&1 && echo "重启完成（systemctl）！" || echo "错误：systemctl重启Clash失败"
elif command -v service >/dev/null 2>&1; then
    # 其他系统：service
    service clash restart >/dev/null 2>&1 && echo "重启完成（service）！" || echo "错误：service重启Clash失败"
else
    echo "警告：未检测到重启方式，请手动重启Clash！"
fi
echo ""

#################### 输出仪表盘信息 ####################
sleep 1
# 适配OPNsense的IP获取（兼容ifconfig/ip命令）
LAN_IP=""
if command -v ip >/dev/null 2>&1; then
    LAN_IP=$(ip addr | grep 'inet ' | grep -v '127.0.0.1' | grep -v 'docker' | grep -v 'tun' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
else
    # FreeBSD/OPNsense的ifconfig格式
    LAN_IP=$(ifconfig 2>/dev/null | awk '/inet / && $2 !~ /^127/ {print $2; exit}' | sed 's/addr://g')
fi
# 兜底IP
LAN_IP=${LAN_IP:-0.0.0.0}

echo "==================== 配置完成 ===================="
echo "仪表盘访问地址: http://${LAN_IP}:9090/ui"
echo "仪表盘访问密钥: ${Secret}"
echo "Clash配置文件: ${Clash_Dir}/config.yaml"
echo "=================================================="
echo ""

#################### 清理临时文件 ####################
rm -f "$TMP_RAW" "$TMP_PROXIES" "$TMP_FINAL"