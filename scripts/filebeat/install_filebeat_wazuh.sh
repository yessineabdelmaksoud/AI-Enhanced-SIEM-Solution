#!/bin/bash
# Install Filebeat on VM-WAZUH-01 to ship Wazuh alerts to Elasticsearch.
# Tails /var/ossec/logs/alerts/alerts.json and writes to wazuh-alerts-*.
# Filebeat version MUST match Elasticsearch (8.13.4). Run as root.
set -euo pipefail
exec > >(tee /var/log/filebeat-wazuh-install.log) 2>&1

# ─── Version OBLIGATOIREMENT identique à Elasticsearch ───────
FB_VERSION="8.13.4"
ES_HOST="https://192.168.56.20:9200"
CA_DEST="/etc/filebeat/ca.crt"
REGISTRY_DIR="/var/lib/filebeat-wazuh"

echo "=== [1/5] Installation Filebeat ${FB_VERSION} ==="
export DEBIAN_FRONTEND=noninteractive

# Repo Elastic (même clé que ES)
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
# CA généré par VM-ELK-01 via dossier partagé Vagrant
cp /vagrant/certs/ca.crt "${CA_DEST}"
chown root:root "${CA_DEST}"
chmod 644 "${CA_DEST}"

# Charger API key
source /vagrant/certs/filebeat_apikeys.env
APIKEY="${FILEBEAT_WAZUH_APIKEY}"

echo "=== [3/5] Configuration filebeat-wazuh.yml ==="
# Désactiver le filebeat.yml par défaut
systemctl disable filebeat 2>/dev/null || true

cat > /etc/filebeat/filebeat-wazuh.yml << FBCONF
# ── Filebeat instance Wazuh ────────────────────────────────
name: "filebeat-wazuh-vm-wazuh-01"

filebeat.inputs:
  - type: log
    id: wazuh-alerts-json
    enabled: true
    paths:
      - /var/ossec/logs/alerts/alerts.json
    json.keys_under_root: true
    json.add_error_key: true
    json.overwrite_keys: true
    # Ne prendre que les lignes JSON valides
    fields:
      source_engine: wazuh
    fields_under_root: true
    # Registry isolé pour cette instance
    close_inactive: 5m
    scan_frequency: 5s

# ── Processors ────────────────────────────────────────────
processors:
  - drop_fields:
      fields: ["host", "ecs", "input", "log"]
      ignore_missing: true

# ── Pipeline ES ───────────────────────────────────────────
setup.ilm.enabled: false
setup.template.enabled: false

# ── Output Elasticsearch avec TLS + API key ───────────────
output.elasticsearch:
  hosts: ["${ES_HOST}"]
  index: "wazuh-alerts-%{+yyyy.MM.dd}"
  pipeline: "wazuh-normalize"
  ssl.enabled: true
  ssl.certificate_authorities: ["${CA_DEST}"]
  ssl.verification_mode: "certificate"
  username: "elastic"
  password: "SocSiem2024!"
  bulk_max_size: 100
  worker: 1

# ── Logging ───────────────────────────────────────────────
logging.level: info
logging.to_files: true
logging.files:
  path: /var/log/filebeat-wazuh
  name: filebeat-wazuh
  keepfiles: 5
  permissions: 0640

# ── Registry isolé (évite conflits avec Filebeat par défaut) ─
filebeat.registry.path: ${REGISTRY_DIR}
FBCONF

# Dossier registry isolé
install -d -m 0750 -o root -g root "${REGISTRY_DIR}"

# Dossier logs
install -d -m 0750 /var/log/filebeat-wazuh

echo "=== [4/5] Service systemd filebeat-wazuh ==="
cat > /etc/systemd/system/filebeat-wazuh.service << 'UNIT'
[Unit]
Description=Filebeat - Wazuh alerts shipper
Documentation=https://www.elastic.co/
After=network-online.target
Wants=network-online.target
# Attendre que wazuh-manager soit actif
After=wazuh-manager.service

[Service]
Type=simple
User=root
ExecStartPre=/usr/share/filebeat/bin/filebeat test config \
  -c /etc/filebeat/filebeat-wazuh.yml
ExecStart=/usr/share/filebeat/bin/filebeat \
  -c /etc/filebeat/filebeat-wazuh.yml \
  --path.home /usr/share/filebeat \
  --path.config /etc/filebeat \
  --path.data /var/lib/filebeat-wazuh \
  --path.logs /var/log/filebeat-wazuh
Restart=on-failure
RestartSec=10
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
UNIT

echo "=== [5/5] Test config + démarrage ==="
/usr/share/filebeat/bin/filebeat test config \
  -c /etc/filebeat/filebeat-wazuh.yml && echo "OK : config valide"

/usr/share/filebeat/bin/filebeat test output \
  -c /etc/filebeat/filebeat-wazuh.yml && echo "OK : connexion ES établie"

systemctl daemon-reload
systemctl enable filebeat-wazuh
systemctl start filebeat-wazuh

sleep 5
if systemctl is-active --quiet filebeat-wazuh; then
  echo "OK : filebeat-wazuh actif"
else
  journalctl -u filebeat-wazuh -n 30 --no-pager
  exit 1
fi

echo "=== FILEBEAT-WAZUH INSTALLÉ ==="