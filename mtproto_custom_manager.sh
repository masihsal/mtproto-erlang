#!/usr/bin/env bash
# MTProto Erlang Custom Manager — side-by-side installer
# Installs a separate seriyps/mtproto_proxy instance; does not replace SalaRNd.
set -Eeuo pipefail

APP_DIR="/opt/mtproto-custom"
DB_DIR="/etc/mtproto-custom"
DB_FILE="$DB_DIR/secrets.json"
UNIT_FILE="/etc/systemd/system/mtproto-custom.service"
PORT_DEFAULT="1443"
REPO="https://github.com/seriyps/mtproto_proxy.git"

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run as root: sudo bash $0"
    exit 1
  fi
}
need_root

mkdir -p "$DB_DIR"
chmod 700 "$DB_DIR"
if [[ ! -f "$DB_FILE" ]]; then
  printf '[]\n' > "$DB_FILE"
  chmod 600 "$DB_FILE"
fi

install_engine() {
  if [[ -d "$APP_DIR/.git" ]]; then
    echo "Source already exists at $APP_DIR; leaving it unchanged."
  else
    if [[ -e "$APP_DIR" ]]; then
      echo "ERROR: $APP_DIR exists but is not a Git checkout. Refusing to overwrite."
      exit 1
    fi
    apt-get update
    apt-get install -y git make build-essential erlang-nox erlang-dev python3
    OTP_MAJOR="$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null | sed 's/[^0-9].*//')"
    if [[ -z "$OTP_MAJOR" || "$OTP_MAJOR" -lt 25 ]]; then
      echo "ERROR: Erlang/OTP 25+ is required by this project; found ${OTP_MAJOR:-unknown}."
      echo "Install a supported Erlang version first, then rerun this script."
      exit 1
    fi
    git clone --depth 1 "$REPO" "$APP_DIR"
  fi

  cd "$APP_DIR"
  if [[ ! -f config/prod-sys.config ]]; then
    make init-config
  fi
  make

  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Custom Erlang MTProto Proxy (separate instance)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/start.sh
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable mtproto-custom.service
  echo
  echo "Engine built. Add a secret from the menu, then start the service."
}

validate_secret() {
  [[ "$1" =~ ^[a-fA-F0-9]{32}$ ]]
}

save_and_apply() {
  python3 - "$APP_DIR/config/prod-sys.config" "$DB_FILE" <<'PY'
import json, re, sys, secrets
from pathlib import Path

config_path, db_path = map(Path, sys.argv[1:])
items = json.loads(db_path.read_text())
text = config_path.read_text()

# Locate the Erlang {ports, [...]} term and replace only its list.
needle = re.search(r'\{ports\s*,', text)
if not needle:
    raise SystemExit("ERROR: couldn't locate {ports, ...} in prod-sys.config")

start = text.find('[', needle.end())
if start < 0:
    raise SystemExit("ERROR: couldn't locate ports list")

depth = 0
end = None
for i in range(start, len(text)):
    if text[i] == '[':
        depth += 1
    elif text[i] == ']':
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end is None:
    raise SystemExit("ERROR: unbalanced Erlang list in config")

entries = []
for idx, item in enumerate(items, 1):
    name = f"mtp_handler_custom_{idx}"
    port = int(item["port"])
    secret = item["secret"].lower()
    tag = item.get("tag") or secrets.token_hex(16)
    item["tag"] = tag
    entries.append(
        "#{name => " + name +
        ', listen_ip => "0.0.0.0", port => ' + str(port) +
        ', secret => <<"' + secret + '">>, tag => <<"' + tag + '">>}'
    )

new_list = "[" + ",\n          ".join(entries) + "]"
text = text[:start] + new_list + text[end:]
config_path.write_text(text)
db_path.write_text(json.dumps(items, indent=2) + "\n")
PY

  # Reload config using the upstream-supported config reload; don't restart the active
  # SalaRNd service. This custom unit is separate and has its own config directory.
  if systemctl is-active --quiet mtproto-custom.service; then
    echo "Custom service is active. Reloading config..."
    # The upstream Erlang app supports sysconfig reload through its own make target.
    (cd "$APP_DIR" && make update-sysconfig)
    systemctl reload mtproto-custom.service 2>/dev/null || systemctl restart mtproto-custom.service
  else
    echo "Config saved. Start the custom service from the menu."
  fi
}

add_secret() {
  [[ -f "$APP_DIR/config/prod-sys.config" ]] || {
    echo "Install the Erlang engine first (menu option 1)."; return
  }
  read -r -p "Port for this secret (default $PORT_DEFAULT; choose unused port): " port
  port="${port:-$PORT_DEFAULT}"
  if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )); then
    echo "Invalid port."; return
  fi
  if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
    echo "Port $port appears to be in use. Pick another one."; return
  fi
  read -r -p "Secret (32 hex chars; blank = generate): " secret
  if [[ -z "$secret" ]]; then
    secret="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
  fi
  if ! validate_secret "$secret"; then
    echo "Secret must be exactly 32 hexadecimal characters (without dd/ee prefix)."; return
  fi
  python3 - "$DB_FILE" "$port" "$secret" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1]); data=json.loads(p.read_text())
port=int(sys.argv[2]); secret=sys.argv[3].lower()
if any(int(x["port"]) == port for x in data):
    raise SystemExit("That port is already assigned in this manager.")
if any(x["secret"].lower() == secret for x in data):
    raise SystemExit("That secret is already registered.")
data.append({"port":port,"secret":secret})
p.write_text(json.dumps(data,indent=2)+"\n")
PY
  save_and_apply
  echo "Added secret on port $port."
  echo "tg://proxy?server=YOUR_SERVER_IP&port=$port&secret=$secret"
}

remove_secret() {
  python3 - "$DB_FILE" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1]); data=json.loads(p.read_text())
if not data:
    print("No managed secrets."); raise SystemExit
for i,x in enumerate(data,1):
    print(f'{i}) port {x["port"]}  secret {x["secret"]}')
PY
  read -r -p "Number to remove: " number
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then echo "Invalid selection."; return; fi
  python3 - "$DB_FILE" "$number" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); data=json.loads(p.read_text()); n=int(sys.argv[2])
if n<1 or n>len(data): raise SystemExit("Selection out of range.")
data.pop(n-1); p.write_text(json.dumps(data,indent=2)+"\n")
PY
  save_and_apply
  echo "Secret removed from config. Apply/reload the custom service if it is running."
}

list_secrets() {
  python3 - "$DB_FILE" <<'PY'
import json,sys
from pathlib import Path
data=json.loads(Path(sys.argv[1]).read_text())
if not data: print("No managed secrets.")
for i,x in enumerate(data,1):
    print(f'{i}) port={x["port"]} secret={x["secret"]}')
PY
}

start_service() {
  if [[ ! -f "$APP_DIR/config/prod-sys.config" ]]; then
    echo "Install engine first."; return
  fi
  if [[ "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))) )' "$DB_FILE")" -eq 0 ]]; then
    echo "Add at least one secret first."; return
  fi
  systemctl start mtproto-custom.service
  systemctl --no-pager --full status mtproto-custom.service
}

status_service() {
  systemctl --no-pager --full status mtproto-custom.service || true
  echo
  echo "CPU/RAM snapshot:"
  ps -eo pid,comm,%cpu,%mem,args | grep -E '[b]eam.smp|[m]tproto-custom' || true
}

while true; do
  echo
  echo "=== MTProto Erlang Custom Manager ==="
  echo "1) Install/build separate Erlang engine"
  echo "2) Add secret (each secret uses its own port)"
  echo "3) Remove secret"
  echo "4) List managed secrets"
  echo "5) Start custom service"
  echo "6) Stop custom service"
  echo "7) Restart custom service"
  echo "8) Service status / CPU snapshot"
  echo "9) Exit"
  read -r -p "Select: " choice
  case "$choice" in
    1) install_engine ;;
    2) add_secret ;;
    3) remove_secret ;;
    4) list_secrets ;;
    5) start_service ;;
    6) systemctl stop mtproto-custom.service ;;
    7) systemctl restart mtproto-custom.service ;;
    8) status_service ;;
    9) exit 0 ;;
    *) echo "Invalid choice." ;;
  esac
done
