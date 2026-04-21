#!/bin/bash
echo -e ''
echo -e "\033[32m========Mihomo for OPNsense 一键安装脚本=========\033[0m"
echo -e ''

# 定义颜色变量
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
BLUE="\033[34m"
RESET="\033[0m"

# 定义目录变量
ROOT="/usr/local"
BIN_DIR="$ROOT/bin"
WWW_DIR="$ROOT/www"
CONF_DIR="$ROOT/etc"
MENU_DIR="$ROOT/opnsense/mvc/app/models/OPNsense"
RC_DIR="$ROOT/etc/rc.d"
PLUGINS="$ROOT/etc/inc/plugins.inc.d"
ACTIONS="$ROOT/opnsense/service/conf/actions.d"
RC_CONF="/etc/rc.conf.d/"
CONFIG_FILE="/conf/config.xml"
TMP_FILE="/tmp/config.xml.tmp"
TIMESTAMP=$(date +%F-%H%M%S)
BACKUP_FILE="/conf/config.xml.bak.$TIMESTAMP"
TARGET_IF_BLOCK=""

# 定义日志函数
log() {
    local color="$1"
    local level="$2"
    local message="$3"
    local ts
    ts=$(date '+%F %T')
    echo -e "${color}[${ts}] [${level}] ${message}${RESET}"
}

log_info() {
    log "$YELLOW" "INFO" "$1"
}

log_warn() {
    log "$CYAN" "WARN" "$1"
}

log_error() {
    log "$RED" "ERROR" "$1"
}

log_success() {
    log "$GREEN" "OK" "$1"
}

log_step() {
    log "$BLUE" "STEP" "$1"
}

# 创建目录
log_step "创建目录..."
mkdir -p "$CONF_DIR/mihomo" "$CONF_DIR/mosdns" "$RC_CONF" || log_error "目录创建失败！"

# 复制文件
log_step "复制文件并部署组件..."
log_info "生成菜单..."
log_info "生成服务..."
log_info "添加权限..."

chmod +x ./bin/* ./rc.d/* 2>/dev/null
cp -f bin/* "$BIN_DIR/" 2>/dev/null
cp -f www/* "$WWW_DIR/" 2>/dev/null
cp -f rc.d/* "$RC_DIR/" 2>/dev/null
cp -f rc.conf/* "$RC_CONF/" 2>/dev/null
cp -f plugins/* "$PLUGINS/" 2>/dev/null
cp -f actions/* "$ACTIONS/" 2>/dev/null
cp -R -f menu/* "$MENU_DIR/" 2>/dev/null
cp -R -f conf/* "$CONF_DIR/mihomo/" 2>/dev/null
cp -R -f mosdns/* "$CONF_DIR/mosdns/" 2>/dev/null

log_success "文件复制完成"

# 新建订阅程序
log_step "添加订阅..."
cat>/usr/bin/sub<<EOF
# 启动mihomo订阅程序
bash /usr/local/etc/mihomo/sub/sub.sh
EOF
chmod +x /usr/bin/sub
log_success "订阅程序添加完成"

# 安装bash
log_step "检查并安装 bash..."
if ! pkg info -q bash > /dev/null 2>&1; then
  if pkg install -y bash > /dev/null 2>&1; then
    log_success "bash 安装完成"
  else
    log_error "bash 安装失败"
  fi
else
  log_warn "bash 已安装，跳过"
fi

# 启动服务
log_step "启动 mihomo 与 mosdns..."
service mihomo stop 2>/dev/null
service mosdns stop 2>/dev/null
sleep 1

if service mihomo start > /dev/null 2>&1; then
  log_success "mihomo 启动完成"
else
  log_error "mihomo 启动失败"
fi

if service mosdns start > /dev/null 2>&1; then
  log_success "mosdns 启动完成"
else
  log_error "mosdns 启动失败"
fi
echo ""

# 备份配置文件
log_step "备份配置文件..."
cp "$CONFIG_FILE" "$BACKUP_FILE" || {
  log_error "配置备份失败，终止操作！"
  echo ""
  exit 1
}
log_success "配置已备份到 $BACKUP_FILE"

# 自动获取可用OPT接口
TARGET_IF_BLOCK=$(awk '
BEGIN {
  in_block = 0
  current = ""
  found = ""
  max_opt = -1
}
{
  if ($0 ~ /^[[:space:]]*<opt[0-9]+>[[:space:]]*$/) {
    line = $0
    gsub(/^[[:space:]]*</, "", line)
    gsub(/>[[:space:]]*$/, "", line)
    current = line
    in_block = 1
    num = current
    sub(/^opt/, "", num)
    if ((num + 0) > max_opt) max_opt = num + 0
  }
  if (in_block && $0 ~ /<if>tun_3000<\/if>/) found = current
  if (in_block && current != "" && $0 ~ ("^[[:space:]]*</" current ">[[:space:]]*$")) {
    in_block = 0
    current = ""
  }
}
END {
  if (found != "") print found
  else print "opt" (max_opt + 1)
}
' "$CONFIG_FILE")

log_info "tun_3000 目标接口块：$TARGET_IF_BLOCK"

# 添加tun接口
log_step "添加 tun_3000 接口..."
if grep -q "<if>tun_3000</if>" "$CONFIG_FILE"; then
  log_warn "存在同名接口，忽略"
else
  awk -v target="$TARGET_IF_BLOCK" '
  BEGIN { inserted = 0 }
  { print }
  /<\/lo0>/ && inserted == 0 {
    print "    <" target ">"
    print "      <if>tun_3000</if>"
    print "      <descr>TUN</descr>"
    print "      <enable>1</enable>"
    print "    </" target ">"
    inserted = 1
  }
  END { exit inserted == 0 ? 1 : 0 }
  ' "$CONFIG_FILE" > "$TMP_FILE"

  if [ $? -eq 0 ] && [ -s "$TMP_FILE" ]; then
    mv "$TMP_FILE" "$CONFIG_FILE"
    log_success "${TARGET_IF_BLOCK} 接口添加完成"
  else
    rm -f "$TMP_FILE"
    log_error "接口添加失败，请检查配置文件"
  fi
fi
echo ""

# 添加防火墙规则（允许TUN子网互访问）
# 添加防火墙规则（允许TUN子网互访问）【完美修复版】
# 添加防火墙规则（允许TUN子网互访问）【OPNsense 原生终版】
log_step "添加防火墙规则..."
RULE_UUID="5a73c3dc-69b1-4e15-89cb-b542aa2c1154"

# 先判断规则是否已存在
if grep -q "${RULE_UUID}" "$CONFIG_FILE"; then
  log_warn "存在同名规则，跳过添加"
else

awk -v uuid="$RULE_UUID" -v iface="$TARGET_IF_BLOCK" '
BEGIN { inserted = 0 }
{
    print
    # 找到filter闭合标签，在它前面插入完整规则
    if ($0 ~ /<\/filter>/ && inserted == 0) {
printf "          <rule uuid=\"%s\">\n", uuid
print "            <enabled>1</enabled>"
print "            <statetype>keep</statetype>"
print "            <sequence>200</sequence>"
print "            <action>pass</action>"
print "            <quick>1</quick>"
print "            <interface>" iface "</interface>"
print "            <direction>in</direction>"
print "            <ipprotocol>inet</ipprotocol>"
print "            <protocol>any</protocol>"
print "            <source_net>" iface "</source_net>"
print "            <destination_net>" iface "</destination_net>"
print "            <description>TUN子网内部互通</description>"
print "          </rule>"
        inserted = 1
    }
}
END { exit inserted ? 0 : 1 }
' "$CONFIG_FILE" > "$TMP_FILE"

  # 校验写入结果
  if [ $? -eq 0 ] && [ -s "$TMP_FILE" ]; then
    cp -f "$TMP_FILE" "$CONFIG_FILE"
    log_success "${TARGET_IF_BLOCK} TUN防火墙规则添加成功"
  else
    rm -f "$TMP_FILE"
    log_error "防火墙规则写入失败"
  fi
fi
echo ""

# 更改Unbound端口为 5355
sleep 1
log_step "更改 Unbound 端口..."

UNBOUND_STATE=$(awk '
BEGIN { in_unbound=0; in_general=0; has_5355=0; has_other=0 }
{
  if ($0 ~ /<unbound/ || $0 ~ /<unboundplus>/) in_unbound=1
  if (in_unbound && $0 ~ /<general>/) in_general=1
  if (in_unbound && in_general && $0 ~ /<port>5355<\/port>/) has_5355=1
  if (in_unbound && in_general && $0 ~ /<port>[0-9]+<\/port>/ && $0 !~ /5355/) has_other=1
  if (in_unbound && $0 ~ /<\/general>/) in_general=0
  if ($0 ~ /<\/unbound/ || $0 ~ /<\/unboundplus>/) in_unbound=0
}
END {
  if (has_5355) print "already_ok"
  else if (has_other) print "need_replace"
  else print "need_insert"
}
' "$CONFIG_FILE")

if [ "$UNBOUND_STATE" = "already_ok" ]; then
  log_warn "端口已经为 5355，跳过"
else
  awk '
  BEGIN { in_unbound=0; in_general=0; port_handled=0 }
  {
    if ($0 ~ /<unbound/ || $0 ~ /<unboundplus>/) in_unbound=1
    if (in_unbound && $0 ~ /<general>/) { in_general=1; print; next }
    if (in_unbound && in_general && $0 ~ /<\/general>/) {
      if (port_handled==0) print "        <port>5355</port>"
      port_handled=1; in_general=0; print; next
    }
    if (in_unbound && in_general && $0 ~ /<port>[0-9]+<\/port>/) {
      sub(/<port>[0-9]+<\/port>/,"<port>5355</port>")
      port_handled=1; print; next
    }
    print
    if ($0 ~ /<\/unbound/ || $0 ~ /<\/unboundplus>/) { in_unbound=0; in_general=0 }
  }
  END { exit port_handled == 0 ? 1 : 0 }
  ' "$CONFIG_FILE" > "$TMP_FILE"

  if [ $? -eq 0 ] && [ -s "$TMP_FILE" ]; then
    mv "$TMP_FILE" "$CONFIG_FILE"
    log_success "端口已设置为 5355"
  else
    rm -f "$TMP_FILE"
    log_error "修改失败，请检查配置文件"
  fi
fi
echo ""

# 清理缓存
log_step "清理菜单缓存..."
mkdir -p /var/lib/php/tmp 2>/dev/null
rm -f /var/lib/php/tmp/opnsense_menu_cache.xml
rm -f /var/lib/php/tmp/opnsense_acl_cache.json
log_success "菜单缓存清理完成"

# 重新载入configd
log_step "重新载入 configd..."
if service configd restart > /dev/null 2>&1; then
  log_success "configd 重新载入完成"
else
  log_error "configd 重新载入失败"
fi
echo ""

# 重启 Unbound DNS
log_step "重启 Unbound DNS..."
configctl unbound restart > /dev/null 2>&1
log_success "Unbound DNS 重启完成"
echo ""

# 重新加载防火墙
log_step "重新加载防火墙规则..."
configctl filter reload > /dev/null 2>&1
log_success "防火墙规则重新加载完成"
echo ""

# 完成
log_success "====================================================="
log_success "安装完毕！请到 Web 面板 → VPN → 代理 进行配置"
log_success "====================================================="
echo ""