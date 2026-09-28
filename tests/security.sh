#!/usr/bin/env bash
set -euo pipefail

PYTHON=$(command -v python3)
# shellcheck source=../addipv6.sh
source "$(dirname "$0")/../addipv6.sh"
python3() { "$PYTHON" "$@"; }
choose_interface() { SELECTED_IFACE=eth0; }
prepare_state() { :; }
save_record() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$EVENTS"; }
current_source() { printf '2001:db8::1\n'; }
global_addresses() {
    printf '2001:db8::1/64\n2001:db8::2/64\n2001:db8::3/64\n'
}
ip() { printf 'ip %s\n' "$*" >> "$EVENTS"; }

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
EVENTS=$TEST_DIR/events
STATE_FILE=$TEST_DIR/state
: > "$EVENTS"

# 批量上限必须阻止执行 ip；实际生成的地址应位于所选前缀。
if (add_random_ipv6 <<< '1001') > "$TEST_DIR/out" 2>&1; then
    echo '未拦住超出上限的数量' >&2; exit 1
fi
[[ ! -s $EVENTS ]]
add_random_ipv6 <<< '3' > "$TEST_DIR/out"
[[ $(grep -c '^ip -6 addr add ' "$EVENTS") -eq 3 ]]
"$PYTHON" - "$EVENTS" <<'PY'
import ipaddress
import sys
for line in open(sys.argv[1]):
    if line.startswith('ip -6 addr add '):
        address = line.split()[4]
        assert ipaddress.ip_interface(address).ip in ipaddress.ip_network('2001:db8::/64')
PY

# 不信任旧记录：仅删除所选网卡的合法记录，且保留当前出口。
: > "$EVENTS"
cat > "$STATE_FILE" <<'STATE'
eth0 2001:db8::1/64
eth0 2001:db8::2/64
eth1 2001:db8::3/64
eth0 invalid
STATE
delete_all_ipv6 > "$TEST_DIR/out" 2>&1
[[ $(grep -c '^ip -6 addr del ' "$EVENTS") -eq 1 ]]
grep -Fq 'ip -6 addr del 2001:db8::2/64 dev eth0' "$EVENTS"
! grep -Fq 'ip -6 addr del 2001:db8::1/64' "$EVENTS"

# 清空其他地址需要明确确认；确认后也不能删除出口地址。
: > "$EVENTS"
delete_except_default_ipv6 <<< 'no' > "$TEST_DIR/out"
[[ ! -s $EVENTS ]]
delete_except_default_ipv6 <<< 'DELETE' > "$TEST_DIR/out"
[[ $(grep -c '^ip -6 addr del ' "$EVENTS") -eq 2 ]]
! grep -Fq 'ip -6 addr del 2001:db8::1/64' "$EVENTS"

echo 'security smoke tests passed'
