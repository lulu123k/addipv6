#!/usr/bin/env bash
set -u
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

STATE_DIR=/var/lib/addipv6
STATE_FILE=$STATE_DIR/managed-addresses
ROUTE_UNIT=/etc/systemd/system/addipv6-route.service
MAX_ADD=1000

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
warn() { printf '警告：%s\n' "$*" >&2; }

valid_iface() { [[ $1 =~ ^[a-zA-Z0-9_.-]{1,15}$ ]]; }

valid_ipv6() {
    python3 - "$1" <<'PY'
import ipaddress
import sys
try:
    sys.exit(0 if ipaddress.ip_address(sys.argv[1]).version == 6 else 1)
except ValueError:
    sys.exit(1)
PY
}

valid_prefix() {
    python3 - "$1" <<'PY'
import ipaddress
import sys
try:
    sys.exit(0 if ipaddress.ip_interface(sys.argv[1]).version == 6 else 1)
except ValueError:
    sys.exit(1)
PY
}

prepare_state() {
    [[ ! -L $STATE_DIR ]] || die "$STATE_DIR 不能是符号链接。"
    if [[ -e $STATE_DIR ]]; then
        [[ -d $STATE_DIR && $(stat -c %u "$STATE_DIR") -eq 0 ]] || die "$STATE_DIR 必须是 root 拥有的目录。"
    else
        mkdir -m 700 "$STATE_DIR" || die "无法创建 $STATE_DIR。"
    fi
    chmod 700 "$STATE_DIR" || die "无法限制 $STATE_DIR 的权限。"
    [[ ! -L $STATE_FILE ]] || die "$STATE_FILE 不能是符号链接。"
    if [[ -e $STATE_FILE ]]; then
        [[ -f $STATE_FILE && $(stat -c %u "$STATE_FILE") -eq 0 ]] || die "$STATE_FILE 必须是 root 拥有的普通文件。"
        chmod 600 "$STATE_FILE" || die "无法限制 $STATE_FILE 的权限。"
    fi
}

save_record() {
    local iface=$1 prefix=$2 action=$3 tmp line
    prepare_state
    tmp=$(mktemp "$STATE_DIR/.managed-addresses.XXXXXXXX") || die '无法创建临时状态文件。'
    if [[ -f $STATE_FILE ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $action != remove || $line != "$iface $prefix" ]]; then
                printf '%s\n' "$line" >> "$tmp" || { rm -f -- "$tmp"; die '无法写入状态文件。'; }
            fi
        done < "$STATE_FILE"
    fi
    if [[ $action == add ]] && ! grep -Fxq -- "$iface $prefix" "$tmp"; then
        printf '%s %s\n' "$iface" "$prefix" >> "$tmp" || { rm -f -- "$tmp"; die '无法写入状态文件。'; }
    fi
    mv -f -- "$tmp" "$STATE_FILE" || { rm -f -- "$tmp"; die '无法保存状态文件。'; }
}

global_addresses() { ip -o -6 addr show dev "$1" scope global | awk '{print $4}'; }
current_source() { ip -6 route show default dev "$1" | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}'; }

# 2. 用来选择具有全局 IPv6 的网卡
function choose_interface() {
    local iface answer
    local -a interfaces=()
    while IFS= read -r iface; do
        iface=${iface%%@*}
        valid_iface "$iface" || continue
        if ip -6 addr show dev "$iface" scope global | grep -q 'inet6 '; then
            interfaces+=("$iface")
        fi
    done < <(ip -o link show | awk -F': ' '{print $2}')
    if ((${#interfaces[@]} == 0)); then
        die '未找到有全局 IPv6 的网卡。'
    fi
    if ((${#interfaces[@]} == 1)); then
        SELECTED_IFACE=${interfaces[0]}
    else
        echo '请选择网卡：'
        for i in "${!interfaces[@]}"; do
            printf '%d) %s\n' "$((i+1))" "${interfaces[i]}"
        done
        read -r -p '编号: ' answer
        [[ $answer =~ ^[1-9][0-9]*$ ]] && ((answer <= ${#interfaces[@]})) || die '网卡编号无效。'
        SELECTED_IFACE=${interfaces[answer-1]}
    fi
    printf '网卡：%s\n' "$SELECTED_IFACE"
}

# 3. 添加随机 IPv6 地址函数
function add_random_ipv6() {
    local ipv6_cidr count generated prefix added=0 failed=0
    choose_interface
    ipv6_cidr=$(global_addresses "$SELECTED_IFACE" | head -n 1)
    [[ -n $ipv6_cidr ]] && valid_prefix "$ipv6_cidr" || die '未找到合法的全局 IPv6 前缀。'
    read -r -p "要添加多少个 IPv6 地址（1-$MAX_ADD）: " count || die '没有收到数量。'
    [[ $count =~ ^[1-9][0-9]*$ ]] && ((count <= MAX_ADD)) || die '数量无效。'
    # 输入通过 argv 传给 Python，不拼进代码；secrets 从系统随机源取值。
    generated=$(python3 - "$ipv6_cidr" "$count" <<'PY'
import ipaddress
import secrets
import sys

interface = ipaddress.ip_interface(sys.argv[1])
network = interface.network
count = int(sys.argv[2])
if network.prefixlen >= 127 or network.num_addresses - 1 < count:
    sys.exit('网段可用地址不足。')
used = {interface.ip}
for _ in range(count):
    for _ in range(100):
        address = network.network_address + secrets.randbelow(network.num_addresses - 1) + 1
        if address not in used:
            used.add(address)
            print(f'{address}/{network.prefixlen}')
            break
    else:
        sys.exit('生成唯一地址失败。')
PY
) || die '生成随机地址失败。'
    while IFS= read -r prefix; do
        if ip -6 addr add "$prefix" dev "$SELECTED_IFACE"; then
            save_record "$SELECTED_IFACE" "$prefix" add
            printf '已添加：%s\n' "$prefix"
            ((added+=1))
        else
            warn "添加 $prefix 失败。"
            ((failed+=1))
        fi
    done <<< "$generated"
    printf '完成：成功 %d，失败 %d。\n' "$added" "$failed"
    warn '新增公网 IPv6 后，请检查防火墙与监听所有 IPv6 地址的服务。'
}

# 4. 用固定参数的 systemd 单元恢复路由，不向 rc.local 拼接 shell 命令。
persist_route() {
    local iface=$1 gateway=$2 source=$3 ip_bin tmp
    command -v systemctl >/dev/null || { warn '没有 systemd，未启用开机恢复。'; return 1; }
    valid_iface "$iface" && valid_ipv6 "$gateway" && valid_ipv6 "$source" || die '路由参数校验失败。'
    [[ ! -L $ROUTE_UNIT ]] || die "$ROUTE_UNIT 不能是符号链接。"
    if [[ -e $ROUTE_UNIT ]]; then
        [[ -f $ROUTE_UNIT && $(stat -c %u "$ROUTE_UNIT") -eq 0 ]] || die "$ROUTE_UNIT 必须是 root 拥有的普通文件。"
    fi
    ip_bin=$(command -v ip)
    [[ $ip_bin == /* ]] || die '找不到 ip 命令的绝对路径。'
    tmp=$(mktemp /etc/systemd/system/.addipv6-route.XXXXXXXX) || die '无法创建临时服务文件。'
    if ! cat > "$tmp" <<EOF
[Unit]
Description=Restore addipv6 IPv6 default route
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$ip_bin -6 route replace default via $gateway dev $iface src $source onlink

[Install]
WantedBy=multi-user.target
EOF
    then
        rm -f -- "$tmp"
        die '无法写入服务文件。'
    fi
    chmod 644 "$tmp" || { rm -f -- "$tmp"; die '无法设置服务文件权限。'; }
    mv -f -- "$tmp" "$ROUTE_UNIT" || { rm -f -- "$tmp"; die '无法保存服务文件。'; }
    systemctl daemon-reload && systemctl enable addipv6-route.service || die '启用开机恢复失败。'
    printf '已启用 %s。请确认源地址在重启后仍会配置到网卡。\n' "$ROUTE_UNIT"
}

function manage_default_ipv6() {
    local -a ipv6_list=()
    local answer source gateway route
    choose_interface
    mapfile -t ipv6_list < <(global_addresses "$SELECTED_IFACE")
    ((${#ipv6_list[@]})) || die '网卡上没有全局 IPv6 地址。'
    for i in "${!ipv6_list[@]}"; do
        printf '%d) %s\n' "$((i+1))" "${ipv6_list[i]}"
    done
    read -r -p '出口地址编号: ' answer || die '没有收到地址编号。'
    [[ $answer =~ ^[1-9][0-9]*$ ]] && ((answer <= ${#ipv6_list[@]})) || die '地址编号无效。'
    source=${ipv6_list[answer-1]%/*}
    valid_ipv6 "$source" || die '出口地址无效。'
    route=$(ip -6 route show default dev "$SELECTED_IFACE" | head -n 1)
    gateway=$(awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}' <<< "$route")
    [[ -n $gateway ]] && valid_ipv6 "$gateway" || die '未找到合法的 IPv6 默认网关。'
    ip -6 route replace default via "$gateway" dev "$SELECTED_IFACE" src "$source" onlink || die '设置默认出口失败。'
    printf '默认出口源地址已设为 %s。\n' "$source"
    read -r -p '要创建 systemd 服务，以便开机恢复此路由吗？(y/N): ' answer || answer=N
    if [[ $answer =~ ^[Yy]$ ]]; then
        persist_route "$SELECTED_IFACE" "$gateway" "$source"
    fi
}

# 5. 只删除记录在 root 私有状态文件里的地址，保留出口和最后一个全局地址。
function delete_all_ipv6() {
    local iface prefix extra source remaining deleted=0 skipped=0
    prepare_state
    [[ -f $STATE_FILE ]] || die '没有本脚本记录的地址。旧版 /tmp 记录不会自动导入。'
    choose_interface
    source=$(current_source "$SELECTED_IFACE")
    remaining=$(global_addresses "$SELECTED_IFACE" | wc -l | tr -d ' ')
    while read -r iface prefix extra || [[ -n ${iface:-} ]]; do
        [[ $iface == "$SELECTED_IFACE" ]] || continue
        if [[ -z ${prefix:-} || -n ${extra:-} ]] || ! valid_prefix "$prefix"; then
            warn "跳过无效记录：$iface ${prefix:-}"
            ((skipped+=1))
            continue
        fi
        if [[ ${prefix%/*} == "$source" || $remaining -le 1 ]]; then
            warn "保留出口或最后一个全局 IPv6：$prefix"
            ((skipped+=1))
            continue
        fi
        if ! global_addresses "$SELECTED_IFACE" | grep -Fxq -- "$prefix"; then
            warn "地址已不在网卡上，清除旧记录：$prefix"
            save_record "$SELECTED_IFACE" "$prefix" remove
            continue
        fi
        if ip -6 addr del "$prefix" dev "$SELECTED_IFACE"; then
            save_record "$SELECTED_IFACE" "$prefix" remove
            printf '已删除：%s\n' "$prefix"
            ((deleted+=1))
            ((remaining-=1))
        else
            warn "删除 $prefix 失败。"
            ((skipped+=1))
        fi
    done < <(cat -- "$STATE_FILE")
    printf '完成：删除 %d，跳过 %d。\n' "$deleted" "$skipped"
}

# 6. 删除网卡上其他全部全局 IPv6，必须有有效的出口并明确确认。
function delete_except_default_ipv6() {
    local source entry answer deleted=0 found=0
    choose_interface
    source=$(current_source "$SELECTED_IFACE")
    [[ -n $source ]] && valid_ipv6 "$source" || die '默认路由没有明确的 IPv6 出口地址，已取消删除。'
    while IFS= read -r entry; do
        [[ ${entry%/*} == "$source" ]] && found=1
    done < <(global_addresses "$SELECTED_IFACE")
    ((found == 1)) || die '出口地址不在所选网卡上。'
    printf '将保留 %s，并删除 %s 上其余所有全局 IPv6 地址。\n' "$source" "$SELECTED_IFACE"
    read -r -p '确认请输入 DELETE: ' answer || die '未收到确认，已取消。'
    [[ $answer == DELETE ]] || { printf '已取消。\n'; return; }
    while IFS= read -r entry; do
        valid_prefix "$entry" || { warn "跳过无效地址：$entry"; continue; }
        [[ ${entry%/*} == "$source" ]] && continue
        if ip -6 addr del "$entry" dev "$SELECTED_IFACE"; then
            save_record "$SELECTED_IFACE" "$entry" remove
            printf '已删除：%s\n' "$entry"
            ((deleted+=1))
        else
            warn "删除 $entry 失败。"
        fi
    done < <(global_addresses "$SELECTED_IFACE")
    printf '完成：删除 %d 个地址，保留 %s。\n' "$deleted" "$source"
}

main() {
    [[ $(id -u) -eq 0 ]] || die '请以 root 身份运行。'
    command -v ip >/dev/null || die '缺少 iproute2 的 ip 命令。'
    command -v python3 >/dev/null || die '缺少 python3。'
    python3 -c 'import secrets' >/dev/null 2>&1 || die '需要支持 secrets 模块的 Python 3.6 或更新版本。'
    local choice_option
    echo '请选择功能：'
    echo '1. 添加随机 IPv6 地址'
    echo '2. 管理默认出口 IPv6 地址'
    echo '3. 删除本脚本记录的 IPv6 地址（保留出口和最后一个地址）'
    echo '4. 仅保留当前出口 IPv6 地址（删除网卡上其他全部全局地址）'
    read -r -p '请输入选择 (1-4): ' choice_option || die '没有收到选择。'
    case $choice_option in
        1) add_random_ipv6 ;;
        2) manage_default_ipv6 ;;
        3) delete_all_ipv6 ;;
        4) delete_except_default_ipv6 ;;
        *) die '无效的选择。' ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
