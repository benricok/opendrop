#!/usr/bin/env bash
set -uo pipefail

# --- Argument Parsing ---
MUTE_TSHARK=0
OPENDROP_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: ./airdrop.sh [--mutetshark] [opendrop arguments...]"
            echo ""
            echo "Wrapper Options:"
            echo "  --mutetshark    Suppress TSHARK output in the terminal"
            echo "  -h, --help      Show this help message along with OpenDrop's help"
            echo ""
            echo "--- OpenDrop Help ---"
            opendrop --help
            exit 0
            ;;
        --mutetshark)
            MUTE_TSHARK=1
            shift
            ;;
        *)
            # Collect all other arguments for opendrop
            OPENDROP_ARGS+=("$1")
            shift
            ;;
    esac
done

# Default OpenDrop arguments if none are provided
if [ ${#OPENDROP_ARGS[@]} -eq 0 ]; then
    OPENDROP_ARGS=(-d -n fedora -m "MacBookPro15,2" receive)
fi

WLAN_IF="wlp0s20f3"
AWDL_IF="awdl0"
FREQ="5220" # Channel 44
OWL_BIN="/home/benrico/Projects/owl/build/daemon/owl"

# ANSI Colors
CLR_RESET="\033[0m"
CLR_SYS="\033[1;33m"   # Bold Yellow
CLR_OWL="\033[1;32m"   # Bold Green
CLR_DROP="\033[1;36m"  # Bold Cyan
CLR_BLE="\033[1;35m"   # Bold Magenta
CLR_TSH="\033[1;34m"   # Bold Blue
CLR_ERR="\033[1;31m"   # Bold Red

CLEANED_UP=0

log_sys() { echo -e "${CLR_SYS}[ SYSTEM   ]${CLR_RESET} $1"; }
log_err() { echo -e "${CLR_ERR}[ ERROR    ]${CLR_RESET} $1"; }

pipe_tag() {
    local tag="$1"
    local color="$2"
    printf -v padded_tag "%-8s" "$tag"
    while IFS= read -r line || [ -n "$line" ]; do
        echo -e "${color}[ ${padded_tag} ]${CLR_RESET} ${line}"
    done
}

start_tshark() {
    local filter="$1"
    if [ "$MUTE_TSHARK" -eq 1 ]; then
        sudo tshark -n -l -i "$WLAN_IF" -Y "$filter" >/dev/null 2>&1 &
    else
        sudo tshark -n -l -i "$WLAN_IF" -Y "$filter" 2>&1 | pipe_tag "TSHARK" "$CLR_TSH" &
    fi
}

cleanup() {
    if [ "$CLEANED_UP" -eq 1 ]; then return; fi
    CLEANED_UP=1
    
    local exit_code=$?
    echo ""
    log_sys "Cleaning up processes and restoring network state (Exit code: ${exit_code})..."

    sudo killall -9 owl opendrop python3 tshark 2>/dev/null || true
    kill $(jobs -p) 2>/dev/null || true
    bluetoothctl advertise off >/dev/null 2>&1 || true

    log_sys "Restoring $WLAN_IF to managed mode..."
    sudo ip link set dev "$WLAN_IF" down 2>/dev/null || true
    sudo iw dev "$WLAN_IF" set type managed 2>/dev/null || true
    
    log_sys "Restarting background network services..."
    sudo systemctl start wpa_supplicant 2>/dev/null || true
    sudo nmcli dev set "$WLAN_IF" managed yes 2>/dev/null || true
    sudo ip link set "$WLAN_IF" up 2>/dev/null || true
    
    sudo nmcli radio wifi off
    sleep 1
    sudo nmcli radio wifi on

    log_sys "Waiting for interface initialization..."
    sleep 5 

    log_sys "Triggering NetworkManager autoconnect..."
    sudo nmcli device connect "$WLAN_IF" 2>/dev/null || {
        sudo nmcli connection up id "$(nmcli -t -f NAME,DEVICE connection show --active | grep "$WLAN_IF" | cut -d: -f1)" 2>/dev/null || true
    }
    
    log_sys "Network restoration complete."
}

trap cleanup EXIT INT TERM

sudo -v

MAC_ADDR=$(cat /sys/class/net/"$WLAN_IF"/address | tr -d '\n')

log_sys "Stopping conflicting network services..."
sudo killall -9 owl opendrop tshark 2>/dev/null || true
sudo nmcli dev disconnect "$WLAN_IF" 2>/dev/null || true
sudo nmcli dev set "$WLAN_IF" managed no
sudo systemctl stop wpa_supplicant

log_sys "Converting $WLAN_IF directly to monitor mode..."
sudo ip link set dev "$WLAN_IF" down
sudo iw dev "$WLAN_IF" set type monitor

sudo ip link set dev "$WLAN_IF" up

log_sys "Tuning $WLAN_IF to $FREQ MHz (Channel 44)..."
TUNE_OUT=$(sudo iw dev "$WLAN_IF" set freq "$FREQ" 2>&1) || log_err "Frequency tune failed: $TUNE_OUT"

sudo ip link set dev "$WLAN_IF" up

log_sys "Current $WLAN_IF status:"
iw dev "$WLAN_IF" info | pipe_tag "NETWORK" "$CLR_SYS"

log_sys "Ensuring firewall rules are present..."
sudo firewall-cmd --zone=trusted --add-interface="$AWDL_IF" >/dev/null 2>&1 || true
sudo firewall-cmd --zone=trusted --add-port=8771/tcp >/dev/null 2>&1 || true

log_sys "Starting Apple AirDrop BLE advertiser..."
cat << 'EOF' > /tmp/airdrop_ble_adv.py
import sys, subprocess, re
def start_adv():
    p = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    p.stdin.write("menu advertise\nclear\nmanufacturer 0x004c 0x05 0x12 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x01 0x00\nback\nadvertise on\n")
    p.stdin.flush()
    print("BLE beacon active.")
    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    allowed = ("Advertising object registered", "Manufacturer:", "Tx Power:", "Name:", "Appearance:", "Discoverable:", "RSI:", "Instance:")
    for line in iter(p.stdout.readline, ''):
        clean = ansi_escape.sub('', line).replace('\r', '').replace('[bluetoothctl]>', '').strip()
        if clean and clean.startswith(allowed): print(f"[bluetoothctl] {clean}")
        sys.stdout.flush()
if __name__ == "__main__": start_adv()
EOF

python3 -u /tmp/airdrop_ble_adv.py 2>&1 | pipe_tag "BLE" "$CLR_BLE" &

log_sys "Starting OWL on $WLAN_IF..."
sudo "$OWL_BIN" -i "$WLAN_IF" -N 2>&1 | pipe_tag "OWL" "$CLR_OWL" &

log_sys "Starting tshark capture on $WLAN_IF (Filtering out broadcast beacons)..."
start_tshark "awdl and wlan.da != ff:ff:ff:ff:ff:ff"

log_sys "Waiting for $AWDL_IF interface to appear..."
for i in {1..15}; do
    if ip link show "$AWDL_IF" >/dev/null 2>&1; then break; fi
    sleep 0.5
done

if ip link show "$AWDL_IF" >/dev/null 2>&1; then
    AWDL_MAC=$(ip link show "$AWDL_IF" | awk '/ether/ {print $2}')
    
    log_sys "Starting tshark on $WLAN_IF (Filtering out own AWDL broadcasts from $AWDL_MAC)..."
    start_tshark "awdl and not (wlan.ta == $AWDL_MAC and wlan.da == ff:ff:ff:ff:ff:ff)"

    log_sys "$AWDL_IF active! Waiting for IPv6 Duplicate Address Detection to clear..."
    
    for i in {1..15}; do
        if ! ip -6 addr show dev "$AWDL_IF" | grep -q "tentative"; then
            break
        fi
        sleep 0.5
    done
    
    log_sys "IPv6 ready. Starting OpenDrop receiver..."
    opendrop -i "$AWDL_IF" "${OPENDROP_ARGS[@]}" 2>&1 | pipe_tag "OPENDROP" "$CLR_DROP"
else
    log_sys "Notice: $AWDL_IF not yet detected. OWL is synchronizing..."
fi

log_sys "AirDrop stack ready. Trigger AirDrop on iPhone. Press Ctrl+C to exit and reconnect Wi-Fi."
wait
