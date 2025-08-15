#!/bin/bash

# 双出口路由管理脚本 - 支持 IPv4 / IPv6 / 出口测速 / 自动恢复 / 策略路由
# 修改适配 eth0 为 CN2（策略表 200）、eth1 为 9929（策略表 201）
# 保留原作者注释与结构，便于维护

# ========== 接口与配置区域 ==========

# CN2 出口（eth0）
CN2_IF="eth0"
CN2_GW="10.8.0.1"
CN2_SRC="10.8.0.39"
CN2_NET="10.8.0.0/23"

# 9929 出口（eth1）
NET9929_IF="eth1"
NET9929_GW="10.7.0.1"
NET9929_SRC="10.7.1.15"
NET9929_NET="10.7.0.0/22"

# 静态路由记录文件
ROUTE_LIST="/etc/custom-routes.list"

# IP 隐藏配置
IS_HIDDEN=true

# 控制台颜色定义
CYAN="\033[0;36m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

# 判断是否为 IPv6
is_ipv6() {
    [[ "$1" =~ : ]]
}

# 判断合法 IPv4
is_valid_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] &&
    awk -F. '{for(i=1;i<=4;i++) if($i>255) exit 1}' <<< "$1"
}

# 判断合法 IPv6
is_valid_ipv6() {
    [[ "$1" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]
}

# 隐藏IP函数
hide_ip() {
    local IP="$1"
    if [[ "$IS_HIDDEN" == "true" && "$IP" != "N/A" ]]; then
        if [[ "$IP" =~ : ]]; then
            echo "$IP" | sed -E 's/:[0-9a-fA-F]*:[0-9a-fA-F]*:[0-9a-fA-F]*:[0-9a-fA-F]*$/:*:*:*:*/'
        else
            echo "$IP" | sed -E 's/\.[0-9]+\.[0-9]+$/.*.*/g'
        fi
    else
        echo "$IP"
    fi
}

# 自动安装 bc 模块（用于延迟计算）
install_bc() {
    if command -v apt-get &>/dev/null; then
        apt-get update >/dev/null 2>&1 && apt-get install -y bc >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y bc >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y bc >/dev/null 2>&1
    elif command -v zypper &>/dev/null; then
        zypper install -y bc >/dev/null 2>&1
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm bc >/dev/null 2>&1
    elif command -v apk &>/dev/null; then
        apk add --no-cache bc >/dev/null 2>&1
    else
        return 1
    fi
    return $?
}

# 获取出口 IP 地址
get_exit_ip() {
    local IFACE_NAME="$1" TARGET_TYPE="$2"
    local IP RETRY_COUNT=0 MAX_RETRIES=2
    local URLS

    if [[ "$TARGET_TYPE" == "ipv6" ]]; then
        URLS=("https://v6.ip.sb" "https://ipv6.icanhazip.com")
    else
        URLS=("http://ip.sb" "https://ipv4.icanhazip.com")
    fi

    while [[ $RETRY_COUNT -le $MAX_RETRIES ]]; do
        for URL in "${URLS[@]}"; do
            local CURL_OPTS="-s --interface $IFACE_NAME --connect-timeout 10 --max-time 15"
            [[ "$TARGET_TYPE" == "ipv6" ]] && CURL_OPTS+=" -6" || CURL_OPTS+=" -4"
            IP=$(curl $CURL_OPTS "$URL" 2>/dev/null)

            if [[ "$TARGET_TYPE" == "ipv6" && "$IP" =~ ^[0-9a-fA-F:]+$ ]]; then
                echo "$IP"; return
            elif [[ "$TARGET_TYPE" == "ipv4" && "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "$IP"; return
            fi
        done
        ((RETRY_COUNT++))
        sleep 1
    done
    echo "N/A"
}

# 出口测速核心逻辑
run_speed_test() {
    local TARGET="$1"
    if ! command -v bc &>/dev/null; then
        echo -e "${YELLOW}[*] 正在安装 bc 计算工具...${NC}"
        if ! install_bc; then
            echo -e "${CYAN}[-] 无法自动安装 bc...${NC}"
            exit 1
        fi
        echo -e "${GREEN}[+] bc 安装完成${NC}"
    fi
    echo -e "${YELLOW}[*] 正在测试目标: $TARGET${NC}"
    echo
    DELAY1=$(test_single_exit "9929（eth1）" "$NET9929_IF" "$NET9929_SRC" "$TARGET")
    DELAY2=$(test_single_exit "CN2（eth0）"  "$CN2_IF"     "$CN2_SRC"     "$TARGET")
    echo -e "${BLUE}推荐线路：${NC}"
    if [[ "$DELAY1" == "fail" && "$DELAY2" == "fail" ]]; then
        echo -e "${CYAN}两个出口都测试失败${NC}"
    elif [[ "$DELAY1" == "fail" ]]; then
        echo -e "${CYAN}→ CN2（eth0） ←（9929 无响应）${NC}"
    elif [[ "$DELAY2" == "fail" ]]; then
        echo -e "${GREEN}→ 9929（eth1） ←（CN2 无响应）${NC}"
    elif (( $(echo "$DELAY1 < $DELAY2" | bc -l) )); then
        echo -e "${GREEN}→ 9929（eth1） ← 更低延迟（${DELAY1}ms vs ${DELAY2}ms）${NC}"
    else
        echo -e "${CYAN}→ CN2（eth0） ← 更低延迟（${DELAY2}ms vs ${DELAY1}ms）${NC}"
    fi
    echo
    read -p "按 Enter 键返回主菜单..."
}

# 策略路由配置
setup_policy_routing() {
    echo -e "${BLUE}[*] 正在配置策略路由...${NC}"
    grep -q "eth0_table" /etc/iproute2/rt_tables || echo "200 eth0_table" >> /etc/iproute2/rt_tables
    grep -q "eth1_table" /etc/iproute2/rt_tables || echo "201 eth1_table" >> /etc/iproute2/rt_tables
    ip route show table eth0_table | grep -q "$CN2_NET" || ip route add "$CN2_NET" dev "$CN2_IF" src "$CN2_SRC" table eth0_table
    ip route show table eth0_table | grep -q "default" || ip route add default via "$CN2_GW" dev "$CN2_IF" table eth0_table
    ip route show table eth1_table | grep -q "$NET9929_NET" || ip route add "$NET9929_NET" dev "$NET9929_IF" src "$NET9929_SRC" table eth1_table
    ip route show table eth1_table | grep -q "default" || ip route add default via "$NET9929_GW" dev "$NET9929_IF" table eth1_table
    ip rule show | grep -q "from $CN2_SRC" || ip rule add from "$CN2_SRC" table eth0_table priority 200
    ip rule show | grep -q "from $NET9929_SRC" || ip rule add from "$NET9929_SRC" table eth1_table priority 201
    echo -e "${GREEN}[+] 策略路由配置完成。${NC}"
}

# systemd 启动项配置
persist_policy_routing() {
    cat > /etc/systemd/system/policy-routing.service <<EOF
[Unit]
Description=应用双网卡策略路由
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash $(realpath $0) --setup-policy

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reexec
    systemctl enable policy-routing.service
    echo -e "${GREEN}[+] 已设置开机自动应用策略路由。${NC}"
}

enable_custom_routes_autostart() {
    cat > /etc/systemd/system/custom-routes.service <<EOF
[Unit]
Description=恢复自定义静态路由
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash $(realpath $0) --restore

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reexec
    systemctl enable custom-routes.service
    echo -e "${GREEN}[+] 已设置开机自动恢复静态路由。${NC}"
}

# 主菜单界面
main_menu() {
    while true; do
        clear
        echo -e "${YELLOW}==============================="
        echo -e "[ 嘻嘻比双出口路由管理脚本 ]"
        echo -e "===============================${NC}"
        echo "1) 添加目标 IP 路由"
        echo "2) 删除指定 IP 路由"
        echo "3) 查看当前路由"
        echo "4) 立即恢复所有路由"
        echo "5) 出口测速（公共）"
        echo "6) 出口测速（自定义）"
        echo
        echo -e "${BLUE}--- 自动化设置 ---${NC}"
        echo "7) 启用静态路由开机恢复"
        echo "8) 启用策略路由开机加载"
        echo "9) 关闭自动化设置"
        echo
        echo "0) 退出"
        echo -e "${YELLOW}===============================${NC}"
        read -p ">> 请选择操作 [0-9]: " OPT
        case "$OPT" in
            1) add_route ;;
            2) delete_route ;;
            3) list_routes ;;
            4) restore_routes ;;
            5) speed_test_public ;;
            6) speed_test_custom ;;
            7) enable_custom_routes_autostart; read -p "按 Enter..." ;;
            8) setup_policy_routing; persist_policy_routing; read -p "按 Enter..." ;;
            9) disable_autostart_menu ;;
            0) exit 0 ;;
            *) echo -e "${CYAN}[-] 无效输入，请重新选择${NC}" ;;
        esac
    done
}

# 启动参数支持
case "$1" in
    --restore)
        restore_routes
        exit 0
        ;;
    --setup-policy)
        setup_policy_routing
        exit 0
        ;;
esac

# 启动主界面
main_menu
