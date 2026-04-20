#!/bin/bash
# Exécuté sur VM-SURI-01
set -euo pipefail
exec > >(tee /var/log/filebeat-suricata-install.log) 2>&1

FB_VERSION="8.13.4"
ES_HOST="https://192.168.56.20:9200"
CA_DEST="/etc/filebeat/ca.crt"
REGISTRY_DIR="/var/lib/filebeat-suricata"

echo "=== [1/5] Installation Filebeat ${FB_VERSION} ==="
export DEBIAN_FRONTEND=noninteractive

install -d -m 0755 /usr/share/keyrings
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | gpg --batch --yes --no-tty --dearmor \
  -o /usr/share/keyrings/elasticsearch-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] \
https://artifacts.elastic.co/packages/8.x/apt stable main" \
  > /etc/apt/sources.list.d/elastic-8.x.list

echo "Attente liberation verrou apt/dpkg..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
   || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
   || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
  echo "apt/dpkg est occupe, attente..."
  sleep 5
done

apt-get update -qq
apt-get install -y "filebeat=${FB_VERSION}"
apt-mark hold filebeat

echo "=== [2/5] Récupération CA et API key ==="
cp /vagrant/certs/ca.crt "${CA_DEST}"
chown root:root "${CA_DEST}"
chmod 644 "${CA_DEST}"

source /vagrant/certs/filebeat_apikeys.env
APIKEY="${FILEBEAT_SURICATA_APIKEY}"

echo "=== [3/5] Configuration filebeat-suricata.yml ==="
systemctl disable filebeat 2>/dev/null || true

cat > /etc/filebeat/filebeat-suricata.yml << FBCONF
name: "filebeat-suricata-vm-suri-01"

filebeat.inputs:
  - type: log
    id: suricata-eve-json
    enabled: true
    paths:
      - /var/log/suricata/eve.json
    json.keys_under_root: true
    json.add_error_key: true
    json.overwrite_keys: true
    fields:
      source_engine: suricata
    fields_under_root: true
    close_inactive: 5m
    scan_frequency: 5s

processors:
  # Supprimer tous les événements qui ne sont pas des alertes
  - drop_event:
      when:
        not:
          equals:
            event_type: "alert"
  - drop_fields:
      fields: ["host", "agent", "ecs", "input", "log"]
      ignore_missing: true

setup.ilm.enabled: false
setup.template.enabled: false

output.elasticsearch:
  hosts: ["${ES_HOST}"]
  index: "suricata-eve-%{+yyyy.MM.dd}"
  pipeline: "suricata-normalize"
  ssl.enabled: true
  ssl.certificate_authorities: ["${CA_DEST}"]
  ssl.verification_mode: "certificate"
  username: "elastic"
  password: "SocSiem2024!"
  bulk_max_size: 100
  worker: 1

logging.level: info
logging.to_files: true
logging.files:
  path: /var/log/filebeat-suricata
  name: filebeat-suricata
  keepfiles: 5
  permissions: 0640

filebeat.registry.path: ${REGISTRY_DIR}
FBCONF

install -d -m 0750 "${REGISTRY_DIR}"
install -d -m 0750 /var/log/filebeat-suricata

echo "=== [4/5] Service systemd filebeat-suricata ==="
cat > /etc/systemd/system/filebeat-suricata.service << 'UNIT'
[Unit]
Description=Filebeat - Suricata alerts shipper
Documentation=https://www.elastic.co/
After=network-online.target
Wants=network-online.target
After=suricata.service

[Service]
Type=simple
User=root
ExecStartPre=/usr/share/filebeat/bin/filebeat test config \
  -c /etc/filebeat/filebeat-suricata.yml
ExecStart=/usr/share/filebeat/bin/filebeat \
  -c /etc/filebeat/filebeat-suricata.yml \
  --path.home /usr/share/filebeat \
  --path.config /etc/filebeat \
  --path.data /var/lib/filebeat-suricata \
  --path.logs /var/log/filebeat-suricata
Restart=on-failure
RestartSec=10
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
UNIT

echo "=== [5/5] Test + démarrage ==="
/usr/share/filebeat/bin/filebeat test config \
  -c /etc/filebeat/filebeat-suricata.yml && echo "OK : config valide"

/usr/share/filebeat/bin/filebeat test output \
  -c /etc/filebeat/filebeat-suricata.yml && echo "OK : connexion ES établie"

systemctl daemon-reload
systemctl enable filebeat-suricata
systemctl start filebeat-suricata

sleep 5
if systemctl is-active --quiet filebeat-suricata; then
  echo "OK : filebeat-suricata actif"
else
  journalctl -u filebeat-suricata -n 30 --no-pager
  exit 1
fi

echo "=== FILEBEAT-SURICATA INSTALLÉ ==="