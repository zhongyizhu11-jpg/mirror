#!/bin/bash
# 双出口路由管理脚本 - IPv4/IPv6 / 出口测速 / 自定义静态路由 / 策略路由(基于源地址)
# 映射关系：10.8.x.x -> CN2 -> eth0；10.7.x.x -> 9929 -> eth1

# ===== 配置区(按你的实际网口/网关/源IP/网段填写) =====
CN2_IF="eth0"
CN2_GW="10.8.0.1"
CN2_SRC="10.8.0.39"
CN2_NET="10.8.0.0/23"

NET9929_IF="eth1"
NET9929_GW="10.7.0.1"
NET9929_SRC="10.7.1.15"
NET9929_NET="10.7.0.0/22"

ROUTE_LIST="/etc/custom-routes.list"
IS_HIDDEN=true
# ================================================

set -euo pipefail

CYAN="\033[0;36m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[0;34m"; NC="\033[0m"

is_ipv6(){ [[ "$1" =~ : ]]; }
is_valid_ipv4(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && awk -F. '{for(i=1;i<=4;i++) if($i>255) exit 1}' <<<"$1"; }
is_valid_ipv6(){ [[ "$1" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]; }

hide_ip(){
  local IP="${1:-N/A}"
  if [[ "$IS_HIDDEN" == "true" && "$IP" != "N/A" ]]; then
    if [[ "$IP" =~ : ]]; then
      echo "$IP" | sed -E 's/(:[0-9a-fA-F]{0,4}){4}$/:*:*:*:*/'
    else
      echo "$IP" | sed -E 's/\.[0-9]+\.[0-9]+$/.*.*/'
    fi
  else
    echo "$IP"
  fi
}

need_cmd(){ command -v "$1" &>/dev/null || { echo "缺少命令: $1"; exit 1; }; }

install_bc(){
  command -v bc &>/dev/null && return 0
  if command -v apt-get &>/dev/null; then apt-get update -y >/dev/null 2>&1 && apt-get install -y bc >/dev/null 2>&1
  elif command -v yum &>/dev/null; then yum install -y bc >/dev/null 2>&1
  elif command -v dnf &>/dev/null; then dnf install -y bc >/dev/null 2>&1
  elif command -v zypper &>/dev/null; then zypper install -y bc >/dev/null 2>&1
  elif command -v pacman &>/dev/null; then pacman -S --noconfirm bc >/dev/null 2>&1
  elif command -v apk &>/dev/null; then apk add --no-cache bc >/dev/null 2>&1
  else return 1; fi
}

get_exit_ip(){
  # $1 iface, $2 ipv4/ipv6
  local IFACE="$1" TYP="$2" IP URLS=()
  [[ "$TYP" == "ipv6" ]] && URLS=("https://v6.ip.sb" "https://ipv6.icanhazip.com") || URLS=("https://api.ipify.org" "https://ipv4.icanhazip.com")
  for U in "${URLS[@]}"; do
    IP=$(curl -s --interface "$IFACE" --connect-timeout 5 --max-time 8 $([[ "$TYP" == "ipv6" ]] && echo -6 || echo -4) "$U" 2>/dev/null || true)
    if [[ "$TYP" == "ipv6" && "$IP" =~ : ]]; then echo "$IP"; return; fi
    if [[ "$TYP" == "ipv4" && "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$IP"; return; fi
  done
  echo "N/A"
}

parse_ping_avg_ms(){
  # 从 ping 输出中提取 avg ms（Linux/BusyBox 通用）
  # 形如: "rtt min/avg/max/mdev = 62.647/67.915/70.895/3.736 ms"
  # 或   : "round-trip min/avg/max/stddev = 22.563/24.400/26.888/1.554 ms"
  local S="$1"
  local LINE
  LINE=$(grep -E "min/avg/max" <<<"$S" || true)
  if [[ -z "$LINE" ]]; then echo "fail"; return; fi
  local BLOCK
  BLOCK=$(echo "$LINE" | grep -Eo '=[[:space:]]*[0-9.]+/[0-9.]+/[0-9.]+/[0-9.]+' | head -n1)
  if [[ -z "$BLOCK" ]]; then echo "fail"; return; fi
  # BLOCK 形如 "= 62.647/67.915/70.895/3.736"
  awk -F'/' '{print $2}' <<<"$BLOCK"
}

test_single_exit(){
  # $1 名称; $2 iface; $3 src-ip(仅v4用); $4 目标
  local NAME="$1" IFACE="$2" SRC="$3" TARGET="$4" TYP OUT_IP PING_CMD RES LOSS AVG
  if is_ipv6 "$TARGET"; then
    TYP="ipv6"; OUT_IP=$(get_exit_ip "$IFACE" ipv6)
    PING_CMD=(ping -6 -c 4 -w 5 -I "$IFACE" "$TARGET")
  else
    TYP="ipv4"; OUT_IP=$(get_exit_ip "$IFACE" ipv4)
    PING_CMD=(ping -4 -c 4 -w 5 -I "$SRC" "$TARGET")
  fi

  RES="$("${PING_CMD[@]}" 2>/dev/null || true)"
  LOSS=$(grep -Eo '[0-9]+% packet loss' <<<"$RES" | cut -d% -f1 | head -n1)
  [[ -z "$LOSS" ]] && LOSS=100

  if [[ "$LOSS" == "100" ]]; then
    AVG="fail"
  else
    AVG=$(parse_ping_avg_ms "$RES")
    [[ -z "$AVG" ]] && AVG="fail"
  fi

  {
    echo -e "${BLUE}-- $NAME --${NC}"
    echo -e "出口IP : $(hide_ip "$OUT_IP")"
    if [[ "$AVG" == "fail" ]]; then
      echo -e "平均延迟 : fail"
    else
      printf "平均延迟 : %.3fms\n" "$AVG"
    fi
    echo
  } >&2

  echo "$AVG"
}

run_speed_test(){
  local TARGET="$1" D9929 DCN2
  command -v bc &>/dev/null || install_bc || { echo -e "${YELLOW}请先安装 bc${NC}"; return; }
  echo -e "${YELLOW}[*] 正在测试目标: $TARGET${NC}\n"
  D9929=$(test_single_exit "9929 (${NET9929_IF})" "$NET9929_IF" "$NET9929_SRC" "$TARGET")
  DCN2=$(test_single_exit "CN2  (${CN2_IF})"     "$CN2_IF"     "$CN2_SRC"     "$TARGET")
  echo -e "${BLUE}推荐线路：${NC}"
  if [[ "$D9929" == "fail" && "$DCN2" == "fail" ]]; then
    echo -e "${CYAN}两个出口都失败${NC}"
  elif [[ "$D9929" == "fail" ]]; then
    echo -e "${CYAN}→ CN2(${CN2_IF}) ←（9929无响应）${NC}"
  elif [[ "$DCN2" == "fail" ]]; then
    echo -e "${GREEN}→ 9929(${NET9929_IF}) ←（CN2无响应）${NC}"
  elif (( $(echo "$D9929 < $DCN2" | bc -l) )); then
    echo -e "${GREEN}→ 9929(${NET9929_IF}) ← 更低延迟（${D9929}ms vs ${DCN2}ms）${NC}"
  else
    echo -e "${CYAN}→ CN2(${CN2_IF}) ← 更低延迟（${DCN2}ms vs ${D9929}ms）${NC}"
  fi
  echo; read -p "按 Enter 返回..."
}

speed_test_public(){
  echo
  echo -e "${BLUE}[*] 选择公共测试目标:${NC}"
  echo "1) 8.8.8.8      (Google DNS)"
  echo "2) 1.1.1.1      (Cloudflare DNS)"
  echo "3) 2001:4860:4860::8888 (Google IPv6)"
  echo "0) 返回"
  read -p ">> 请选择 [默认1]: " CH; CH=${CH:-1}
  case "$CH" in
    1) run_speed_test "8.8.8.8" ;;
    2) run_speed_test "1.1.1.1" ;;
    3) run_speed_test "2001:4860:4860::8888" ;;
    0) return ;;
    *) echo -e "${CYAN}无效选择${NC}"; sleep 1 ;;
  esac
}

speed_test_custom(){
  read -p "[*] 请输入要测试的目标 IP: " T
  [[ -z "$T" ]] && { echo "目标不能为空"; sleep 1; return; }
  if is_ipv6 "$T"; then is_valid_ipv6 "$T" || { echo "IPv6 不合法"; sleep 1; return; }
  else is_valid_ipv4 "$T" || { echo "IPv4 不合法"; sleep 1; return; }
  fi
  run_speed_test "$T"
}

add_route(){
  read -p "[*] 请输入目标 IP: " IP
  [[ -z "$IP" ]] && { echo "IP 不能为空"; sleep 1; return; }
  if is_ipv6 "$IP"; then is_valid_ipv6 "$IP" || { echo "IPv6 不合法"; sleep 1; return; }
  else is_valid_ipv4 "$IP" || { echo "IPv4 不合法"; sleep 1; return; }
  fi
  echo -e "${BLUE}选择出口：${NC}\n1) 9929(${NET9929_IF})\n2) CN2(${CN2_IF})"
  read -p ">> 请选择 [1-2]: " CH
  sed -i "/^$IP /d" "$ROUTE_LIST" 2>/dev/null || true
  if is_ipv6 "$IP"; then
    case "$CH" in
      1) ip -6 route replace "$IP/128" dev "$NET9929_IF"; echo "$IP via-9929-v6" >> "$ROUTE_LIST";;
      2) ip -6 route replace "$IP/128" dev "$CN2_IF";     echo "$IP via-cn2-v6"  >> "$ROUTE_LIST";;
      *) echo "无效选择"; sleep 1; return;;
    esac
  else
    case "$CH" in
      1) ip route replace "$IP/32" via "$NET9929_GW" dev "$NET9929_IF" src "$NET9929_SRC"; echo "$IP via-9929" >> "$ROUTE_LIST";;
      2) ip route replace "$IP/32" via "$CN2_GW"    dev "$CN2_IF"     src "$CN2_SRC";     echo "$IP via-cn2"  >> "$ROUTE_LIST";;
      *) echo "无效选择"; sleep 1; return;;
    esac
  fi
  echo -e "${GREEN}已添加路由${NC}"; sleep 1
}

delete_route(){
  if [[ ! -s "$ROUTE_LIST" ]]; then echo "无记录"; sleep 1; return; fi
  mapfile -t ARR < "$ROUTE_LIST"
  for i in "${!ARR[@]}"; do echo "$((i+1))) ${ARR[$i]}"; done
  read -p ">> 选择要删除的编号(或 m 手动): " CH
  if [[ "$CH" == "m" ]]; then
    read -p "输入要删除的目标IP: " IP
    if is_ipv6 "$IP"; then ip -6 route del "$IP/128" 2>/dev/null; else ip route del "$IP/32" 2>/dev/null; fi
    sed -i "/^$IP /d" "$ROUTE_LIST"; echo "已删除"; sleep 1; return
  fi
  [[ ! "$CH" =~ ^[0-9]+$ ]] && { echo "无效编号"; sleep 1; return; }
  idx=$((CH-1)); [[ $idx -lt 0 || $idx -ge ${#ARR[@]} ]] && { echo "超范围"; sleep 1; return; }
  IP=$(awk '{print $1}' <<<"${ARR[$idx]}"); TAG=$(awk '{print $2}' <<<"${ARR[$idx]}")
  if [[ "$TAG" == *v6 ]]; then ip -6 route del "$IP/128" 2>/dev/null; else ip route del "$IP/32" 2>/dev/null; fi
  sed -i "/^$IP /d" "$ROUTE_LIST"; echo "已删除"; sleep 1
}

list_routes(){
  echo -e "${YELLOW}当前静态路由:${NC}"
  if [[ -s "$ROUTE_LIST" ]]; then cat "$ROUTE_LIST"; else echo "(空)"; fi
  echo; read -p "回车返回..."
}

restore_routes(){
  [[ ! -s "$ROUTE_LIST" ]] && { echo "无记录"; sleep 1; return; }
  while read -r L; do
    IP=$(awk '{print $1}' <<<"$L"); TAG=$(awk '{print $2}' <<<"$L")
    case "$TAG" in
      via-9929)    ip route replace "$IP/32" via "$NET9929_GW" dev "$NET9929_IF" src "$NET9929_SRC" ;;
      via-cn2)     ip route replace "$IP/32" via "$CN2_GW"    dev "$CN2_IF"     src "$CN2_SRC"     ;;
      via-9929-v6) ip -6 route replace "$IP/128" dev "$NET9929_IF" ;;
      via-cn2-v6)  ip -6 route replace "$IP/128" dev "$CN2_IF"     ;;
    esac
  done < "$ROUTE_LIST"
  echo -e "${GREEN}已恢复${NC}"; sleep 1
}

# —— 策略路由：表名固定映射，避免搞反 ——
# 表 100: cn2_table  -> eth0/10.8.x.x
# 表 101: net9929_table -> eth1/10.7.x.x
ensure_tables_names(){
  grep -qE '^[[:space:]]*100[[:space:]]+cn2_table$' /etc/iproute2/rt_tables || echo "100 cn2_table" >> /etc/iproute2/rt_tables
  grep -qE '^[[:space:]]*101[[:space:]]+net9929_table$' /etc/iproute2/rt_tables || echo "101 net9929_table" >> /etc/iproute2/rt_tables
}

cleanup_policy_rules(){
  # 清理同源的重复/错误规则
  for S in "$CN2_SRC" "$NET9929_SRC"; do
    while ip rule show | grep -q "from $S "; do
      local LN; LN=$(ip rule show | grep "from $S " | head -n1)
      local PR; PR=$(awk -F: '{print $1}' <<<"$LN" | tr -d ' ')
      ip rule del priority "$PR" 2>/dev/null || true
    done
  done
}

setup_policy_routing(){
  echo -e "${BLUE}[*] 配置策略路由...${NC}"
  ensure_tables_names

  # 刷新并写入表项 —— 严格对应网卡
  ip route flush table cn2_table       2>/dev/null || true
  ip route add   "$CN2_NET" dev "$CN2_IF" src "$CN2_SRC" table cn2_table
  ip route add   default via "$CN2_GW" dev "$CN2_IF"     table cn2_table

  ip route flush table net9929_table   2>/dev/null || true
  ip route add   "$NET9929_NET" dev "$NET9929_IF" src "$NET9929_SRC" table net9929_table
  ip route add   default via "$NET9929_GW" dev "$NET9929_IF"         table net9929_table

  # 清理旧规则并重建正确映射
  cleanup_policy_rules
  ip rule add from "$CN2_SRC"    table cn2_table     priority 100
  ip rule add from "$NET9929_SRC" table net9929_table priority 101

  echo -e "${GREEN}[+] 策略路由就绪（10.8.* 走 ${CN2_IF}；10.7.* 走 ${NET9929_IF}）${NC}"
  sleep 1
}

persist_policy_routing(){
  cat > /etc/systemd/system/policy-routing.service <<EOF
[Unit]
Description=Apply dual-NIC policy routing (source-based)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash $(realpath "$0") --setup-policy
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable policy-routing.service
  echo -e "${GREEN}已设置开机自动应用策略路由${NC}"
  sleep 1
}

enable_custom_routes_autostart(){
  cat > /etc/systemd/system/custom-routes.service <<EOF
[Unit]
Description=Restore custom static routes
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash $(realpath "$0") --restore
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable custom-routes.service
  echo -e "${GREEN}已设置开机恢复静态路由${NC}"
  sleep 1
}

disable_autostart_menu(){
  echo "1) 关闭静态路由自启"
  echo "2) 关闭策略路由自启"
  echo "0) 返回"
  read -p ">> 选择: " C
  case "$C" in
    1) systemctl disable custom-routes.service 2>/dev/null; rm -f /etc/systemd/system/custom-routes.service; echo "已关闭"; sleep 1;;
    2) systemctl disable policy-routing.service 2>/dev/null; rm -f /etc/systemd/system/policy-routing.service; echo "已关闭"; sleep 1;;
    0) ;;
  esac
}

quick_fix_default(){
  # 快速恢复主路由默认出口到 CN2，避免失联
  ip route replace default via "$CN2_GW" dev "$CN2_IF" onlink
  echo "已设置主表默认路由到 ${CN2_IF} ($CN2_GW)"
  sleep 1
}

show_state(){
  echo -e "${YELLOW}--- 当前策略/路由状态 ---${NC}"
  echo "[ip rule show]"; ip rule show
  echo; echo "[cn2_table]"; ip route show table cn2_table || true
  echo; echo "[net9929_table]"; ip route show table net9929_table || true
  echo; echo "[main]"; ip route show
  echo; read -p "回车返回..."
}

main_menu(){
  while true; do
    clear
    echo -e "${YELLOW}=== 双出口策略路由管理 ===${NC}"
    echo "1) 添加目标 IP 路由"
    echo "2) 删除指定 IP 路由"
    echo "3) 查看当前路由列表(自定义)"
    echo "4) 立即恢复所有自定义路由"
    echo "5) 公共出口测速"
    echo "6) 自定义出口测速"
    echo "7) 启用-自定义路由开机恢复"
    echo "8) 配置并启用-策略路由开机加载"
    echo "9) 查看当前策略/路由状态"
    echo "d) 一键把默认路由切到 CN2(救急)"
    echo "0) 退出"
    read -p ">> 请选择 [0-9/d]: " OPT
    case "$OPT" in
      1) add_route ;;
      2) delete_route ;;
      3) list_routes ;;
      4) restore_routes ;;
      5) speed_test_public ;;
      6) speed_test_custom ;;
      7) enable_custom_routes_autostart ;;
      8) setup_policy_routing; persist_policy_routing ;;
      9) show_state ;;
      d|D) quick_fix_default ;;
      0) exit 0 ;;
      *) echo "无效选择"; sleep 1 ;;
    esac
  done
}

# systemd 入口
case "${1:-}" in
  --restore) restore_routes; exit 0 ;;
  --setup-policy) setup_policy_routing; exit 0 ;;
esac

# 运行前的基本检查
need_cmd ip; need_cmd awk; need_cmd sed; need_cmd grep; need_cmd curl
main_menu
