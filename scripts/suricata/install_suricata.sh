#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/suricata-install.log) 2>&1

IFACE="${1:-enp0s8}"
HOME_NET="${2:-192.168.56.0/24}"

echo "=== [0/9] Variables ==="
echo "Interface : ${IFACE}"
echo "HOME_NET  : ${HOME_NET}"

# ── [1] Vérification interface ──────────────────────────────
echo "=== [1/9] Vérification interface ==="
if ! ip link show "${IFACE}" >/dev/null 2>&1; then
  echo "ERREUR : interface ${IFACE} introuvable"
  ip link show
  exit 1
fi

# ── [2] Système ─────────────────────────────────────────────
echo "=== [2/9] Mise à jour système ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

# ── [3] Dépendances ─────────────────────────────────────────
echo "=== [3/9] Dépendances ==="
apt-get install -y -qq \
  software-properties-common \
  curl wget gnupg apt-transport-https \
  lsb-release ca-certificates \
  net-tools ufw jq tcpdump

# ── [4] Installation ─────────────────────────────────────────
echo "=== [4/9] Installation Suricata ==="
add-apt-repository -y ppa:oisf/suricata-stable
apt-get update -qq
apt-get install -y -qq suricata

# ── [5] Sauvegarde ───────────────────────────────────────────
echo "=== [5/9] Sauvegarde config existante ==="
cp -a /etc/suricata/suricata.yaml \
  "/etc/suricata/suricata.yaml.bak.$(date +%F-%H%M%S)"

# ── [6] Configuration ────────────────────────────────────────
echo "=== [6/9] Déploiement suricata.yaml ==="
cat > /etc/suricata/suricata.yaml << EOF
%YAML 1.1
---

vars:
  address-groups:
    HOME_NET: "[${HOME_NET}]"
    EXTERNAL_NET: "!\$HOME_NET"
    HTTP_SERVERS: "\$HOME_NET"
    SMTP_SERVERS: "\$HOME_NET"
    SQL_SERVERS: "\$HOME_NET"
    DNS_SERVERS: "\$HOME_NET"
    TELNET_SERVERS: "\$HOME_NET"
    AIM_SERVERS: "\$EXTERNAL_NET"
    DC_SERVERS: "\$HOME_NET"
    DNP3_SERVER: "\$HOME_NET"
    DNP3_CLIENT: "\$HOME_NET"
    MODBUS_CLIENT: "\$HOME_NET"
    MODBUS_SERVER: "\$HOME_NET"
    ENIP_CLIENT: "\$HOME_NET"
    ENIP_SERVER: "\$HOME_NET"

  port-groups:
    HTTP_PORTS: "80"
    SHELLCODE_PORTS: "!80"
    ORACLE_PORTS: 1521
    SSH_PORTS: 22
    DNP3_PORTS: 20000
    MODBUS_PORTS: 502
    FILE_DATA_PORTS: "[\$HTTP_PORTS,110,143]"
    FTP_PORTS: 21
    GENEVE_PORTS: 6081
    VXLAN_PORTS: 4789
    TEREDO_PORTS: 3544

default-log-dir: /var/log/suricata/

stats:
  enabled: yes
  interval: 60

outputs:
  - eve-log:
      enabled: yes
      filetype: regular
      filename: eve.json
      community-id: true
      community-id-seed: 0
      types:
        - alert:
            metadata: yes
            tagged-packets: yes
            payload: yes
            payload-buffer-size: 4kb
            payload-printable: yes
            packet: yes
            http-body: yes
            http-body-printable: yes
        - anomaly:
            enabled: yes
            types:
              decode: yes
              stream: yes
              applayer: yes
        - http:
            extended: yes
        - dns:
            version: 2
        - tls:
            extended: yes
        - ssh
        - flow
        - files:
            force-magic: yes
        - stats:
            totals: yes
            threads: no
            deltas: no

  - fast:
      enabled: yes
      filename: fast.log
      append: yes

af-packet:
  - interface: ${IFACE}
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
    use-mmap: yes
    tpacket-v3: yes
    ring-size: 200000
    buffer-size: 64535

stream:
  memcap: 128mb
  checksum-validation: yes
  inline: no
  reassembly:
    memcap: 256mb
    depth: 1mb
    toserver-chunk-size: 2560
    toclient-chunk-size: 2560
    randomize-chunk-size: yes

detect:
  profile: medium
  sgh-mpm-context: auto

app-layer:
  protocols:
    tls:
      enabled: yes
      detection-ports:
        dp: 443
    http:
      enabled: yes
    ftp:
      enabled: yes
    ssh:
      enabled: yes
    dns:
      tcp:
        enabled: yes
        detection-ports:
          dp: 53
      udp:
        enabled: yes
        detection-ports:
          dp: 53
    dnp3:
      enabled: no
    modbus:
      enabled: no

logging:
  default-log-level: notice
  outputs:
    - console:
        enabled: no
    - file:
        enabled: yes
        level: info
        filename: /var/log/suricata/suricata.log

default-rule-path: /var/lib/suricata/rules

rule-files:
  - suricata.rules
  - custom.rules
EOF

# ── [7] suricata-update avec disable.conf ────────────────────
echo "=== [7/9] Mise à jour des règles ==="

# Désactiver les règles DNP3 via disable.conf (méthode correcte pour 8.x)
install -d -m 0755 /etc/suricata/update.d
cat > /etc/suricata/update.d/disable.conf << 'DISABLE'
# Désactive les règles DNP3 et Modbus (protocoles SCADA non utilisés dans ce labo)
group:dnp3-events.rules
group:modbus-events.rules
DISABLE

suricata-update \
  --disable-conf /etc/suricata/update.d/disable.conf \
  --no-test

# ── [8] Règles custom — APRÈS suricata-update ────────────────
echo "=== [8/9] Règles custom labo ==="
install -d -m 0755 /var/lib/suricata/rules
# Écrit après suricata-update pour ne pas être écrasé
cat > /var/lib/suricata/rules/custom.rules << 'RULES'
# SSH brute force
alert tcp any any -> $HOME_NET 22 (msg:"SOC-LAB SSH Brute Force Attempt"; \
  flow:to_server; \
  threshold:type threshold,track by_src,count 5,seconds 60; \
  classtype:attempted-admin; sid:9000001; rev:1;)

# Port scan
alert tcp any any -> $HOME_NET any (msg:"SOC-LAB Port Scan Detected"; \
  flags:S; \
  threshold:type threshold,track by_src,count 20,seconds 10; \
  classtype:network-scan; sid:9000002; rev:1;)

# ICMP flood
alert icmp any any -> $HOME_NET any (msg:"SOC-LAB ICMP Flood"; \
  threshold:type threshold,track by_src,count 50,seconds 10; \
  classtype:misc-attack; sid:9000003; rev:1;)

# HTTP user-agent curl
alert http any any -> $HOME_NET any (msg:"SOC-LAB Suspicious User-Agent curl"; \
  flow:to_server,established; \
  http.user_agent; content:"curl"; nocase; \
  classtype:policy-violation; sid:9000004; rev:1;)
RULES

# ── [9] Démarrage ────────────────────────────────────────────
echo "=== [9/9] Validation + démarrage ==="

# Permissions logs
install -d -o suricata -g suricata -m 0750 /var/log/suricata
for f in eve.json fast.log suricata.log; do
  touch /var/log/suricata/${f}
  chown suricata:suricata /var/log/suricata/${f}
  chmod 0640 /var/log/suricata/${f}
done

ufw allow 22/tcp || true
ufw --force enable || true

echo "[TEST] Validation configuration"
if ! suricata -T -c /etc/suricata/suricata.yaml -i "${IFACE}" 2>&1; then
  echo "ERREUR : suricata -T a échoué"
  tail -n 50 /var/log/suricata/suricata.log || true
  exit 1
fi
echo "OK : configuration valide"

systemctl daemon-reload
systemctl enable suricata

if ! systemctl restart suricata; then
  journalctl -u suricata -n 50 --no-pager || true
  exit 1
fi

sleep 5

if ! systemctl is-active --quiet suricata; then
  echo "ERREUR : service suricata inactif"
  journalctl -u suricata -n 50 --no-pager || true
  exit 1
fi

echo "OK : Suricata actif sur ${IFACE}"
echo "OK : eve.json → $(ls -lh /var/log/suricata/eve.json)"
tail -n 10 /var/log/suricata/suricata.log || true
echo "=== INSTALLATION SURICATA TERMINÉE ==="