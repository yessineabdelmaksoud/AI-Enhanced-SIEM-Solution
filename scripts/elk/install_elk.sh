#!/bin/bash
# Install Elasticsearch + Kibana stack on VM-ELK-01.
# Generates CA + node certs, sets elastic/kibana_system passwords,
# enables TLS, and exports credentials to /vagrant/certs/es_credentials.env.
# Versions MUST match across ES/Kibana/Filebeat (8.13.4). Ubuntu 22.04.
# Run as root. Output logged to /var/log/elk-install.log.
set -euo pipefail
exec > >(tee /var/log/elk-install.log) 2>&1

# ════════════════════════════════════════════════════════════
# Versions — tout doit être identique entre ES, Kibana, Filebeat
# Elasticsearch 8.13.4 / Kibana 8.13.4 / Filebeat 8.13.4
# Ubuntu 22.04 LTS (jammy) compatible
# ════════════════════════════════════════════════════════════
ES_VERSION="8.13.4"
ES_IP="192.168.56.20"
ES_PASS="SocSiem2024!"
KIBANA_PASS="KibanaSoc2024!"
CERTS_DIR="/etc/elasticsearch/certs"
VAGRANT_CERTS="/vagrant/certs" 

echo "=== [1/10] Mise à jour système ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

echo "=== [2/10] Dépendances ==="
apt-get install -y -qq \
  curl wget gnupg apt-transport-https \
  lsb-release ca-certificates \
  net-tools ufw unzip jq openssl

echo "=== [3/10] Repo Elastic 8.x ==="
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | gpg --batch --yes --no-tty --dearmor \
  -o /usr/share/keyrings/elasticsearch-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] \
https://artifacts.elastic.co/packages/8.x/apt stable main" \
  > /etc/apt/sources.list.d/elastic-8.x.list

apt-get update -qq

echo "=== [4/10] Installation Elasticsearch ${ES_VERSION} ==="
apt-get install -y "elasticsearch=${ES_VERSION}"
# Pinning de version pour éviter mise à jour accidentelle
apt-mark hold elasticsearch

echo "=== [5/10] Génération CA et certificats ==="
install -d -m 0750 -o root -g elasticsearch "${CERTS_DIR}"

# Génération CA (pem = ca.crt + ca.key)
if [ ! -f "${CERTS_DIR}/ca/ca.crt" ]; then
  /usr/share/elasticsearch/bin/elasticsearch-certutil ca \
    --silent --pem \
    --out "${CERTS_DIR}/ca.zip"
  unzip -o "${CERTS_DIR}/ca.zip" -d "${CERTS_DIR}/"
fi
# Résultat : ${CERTS_DIR}/ca/ca.crt  et  ${CERTS_DIR}/ca/ca.key

# Génération certificat nœud ES (signé par CA)
if [ ! -f "${CERTS_DIR}/instance/instance.crt" ]; then
  /usr/share/elasticsearch/bin/elasticsearch-certutil cert \
    --silent --pem \
    --ca-cert "${CERTS_DIR}/ca/ca.crt" \
    --ca-key  "${CERTS_DIR}/ca/ca.key" \
    --dns "vm-elk-01" \
    --ip  "${ES_IP}" \
    --out "${CERTS_DIR}/node.zip"
  unzip -o "${CERTS_DIR}/node.zip" -d "${CERTS_DIR}/"
fi
# Résultat : ${CERTS_DIR}/instance/instance.crt  et  instance.key

# Permissions strictes
chown -R root:elasticsearch "${CERTS_DIR}"
chmod 750 "${CERTS_DIR}" "${CERTS_DIR}/ca" "${CERTS_DIR}/instance"
chmod 640 \
  "${CERTS_DIR}/ca/ca.crt" \
  "${CERTS_DIR}/ca/ca.key" \
  "${CERTS_DIR}/instance/instance.crt" \
  "${CERTS_DIR}/instance/instance.key"

echo "=== [5b/10] Distribution CA vers /vagrant/certs/ ==="
install -d -m 0755 "${VAGRANT_CERTS}"
cp "${CERTS_DIR}/ca/ca.crt" "${VAGRANT_CERTS}/ca.crt"
echo "CA copié dans ${VAGRANT_CERTS}/ca.crt — disponible pour les autres VMs."

echo "=== [6/10] Configuration elasticsearch.yml ==="
cat > /etc/elasticsearch/elasticsearch.yml << EOF
# ── Cluster ──────────────────────────────────────────────────
cluster.name: soc-siem
node.name: vm-elk-01

# ── Réseau ───────────────────────────────────────────────────
network.host: ${ES_IP}
http.port: 9200
transport.port: 9300

# ── Découverte ───────────────────────────────────────────────
discovery.type: single-node

# ── Chemins ──────────────────────────────────────────────────
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

# ── Sécurité HTTP (TLS + auth) ───────────────────────────────
xpack.security.enabled: true
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.certificate_authorities: ${CERTS_DIR}/ca/ca.crt
xpack.security.http.ssl.certificate: ${CERTS_DIR}/instance/instance.crt
xpack.security.http.ssl.key: ${CERTS_DIR}/instance/instance.key

# ── Sécurité Transport (inter-nœuds) ─────────────────────────
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.certificate_authorities: ${CERTS_DIR}/ca/ca.crt
xpack.security.transport.ssl.certificate: ${CERTS_DIR}/instance/instance.crt
xpack.security.transport.ssl.key: ${CERTS_DIR}/instance/instance.key
EOF

echo "=== [7/10] JVM Heap ==="
cat > /etc/elasticsearch/jvm.options.d/heap.options << 'EOF'
-Xms2g
-Xmx2g
EOF

echo "=== [8/10] Firewall ==="
ufw allow 22/tcp
ufw allow 9200/tcp   # ES HTTP — Filebeat + FastAPI
ufw allow 9300/tcp   # ES Transport — si cluster futur
ufw allow 5601/tcp   # Kibana
ufw --force enable

echo "=== [9/10] Démarrage Elasticsearch ==="
systemctl daemon-reload
systemctl enable elasticsearch
systemctl start elasticsearch

# Attendre que ES soit opérationnel (peut prendre 60-90s)
echo "Attente démarrage Elasticsearch..."
RETRIES=60
until curl -s -o /dev/null -w "%{http_code}" \
    --cacert "${CERTS_DIR}/ca/ca.crt" \
    "https://${ES_IP}:9200/" | grep -qE "^(200|401)$"; do
  RETRIES=$((RETRIES-1))
  if [ $RETRIES -le 0 ]; then
    echo "ERREUR : Elasticsearch non démarré après timeout"
    journalctl -u elasticsearch -n 100 --no-pager
    exit 1
  fi
  echo "Pas encore prêt... (${RETRIES} tentatives restantes)"
  sleep 10
done

echo "=== [9b/10] Génération mots de passe ==="
# Utiliser l'API de reset de mot de passe (ES 8.x)
# Mot de passe elastic fixé pour reproductibilité en labo
ES_PASS="SocSiem2024!"

printf '%s\n%s\n' "${ES_PASS}" "${ES_PASS}" | \
  /usr/share/elasticsearch/bin/elasticsearch-reset-password \
  -u elastic --batch -i

# Vérification connexion avec mot de passe
sleep 5
if curl -s -u "elastic:${ES_PASS}" \
    --cacert "${CERTS_DIR}/ca/ca.crt" \
    "https://${ES_IP}:9200/_cluster/health" | grep -q '"status"'; then
  echo "OK : Elasticsearch opérationnel"
else
  echo "ERREUR : authentification échouée — vérifier le mot de passe"
  exit 1
fi

# Stocker credentials pour les scripts suivants
cat > /vagrant/certs/es_credentials.env << EOF2
ES_HOST=https://192.168.56.20:9200
ES_USER=elastic
ES_PASS=${ES_PASS}
EOF2
chmod 600 /vagrant/certs/es_credentials.env

echo "=== [10/10] Installation Kibana ${ES_VERSION} ==="
apt-get install -y "kibana=${ES_VERSION}"
apt-mark hold kibana

# Mot de passe kibana_system
printf '%s\n%s\n' "${KIBANA_PASS}" "${KIBANA_PASS}" | \
  /usr/share/elasticsearch/bin/elasticsearch-reset-password \
  -u kibana_system --batch -i

cat > /etc/kibana/kibana.yml << EOF3
server.host: "${ES_IP}"
server.name: "vm-elk-01"

elasticsearch.hosts: ["https://${ES_IP}:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${KIBANA_PASS}"

# TLS vers Elasticsearch
elasticsearch.ssl.certificateAuthorities: ["/etc/kibana/ca.crt"]
elasticsearch.ssl.verificationMode: "certificate"

# Kibana lui-même en HTTP (accès interne labo)
server.ssl.enabled: false

logging.appenders.file.type: file
logging.appenders.file.fileName: /var/log/kibana/kibana.log
logging.appenders.file.layout.type: json
logging.root.level: warn
EOF3

# CA pour Kibana
cp "${CERTS_DIR}/ca/ca.crt" /etc/kibana/ca.crt
chown root:kibana /etc/kibana/ca.crt
chmod 640 /etc/kibana/ca.crt

systemctl enable kibana
systemctl start kibana

echo "=== CRÉATION API KEYS FILEBEAT ==="
sleep 10

# API key pour Filebeat-Wazuh
APIKEY_WAZUH=$(curl -s -u "elastic:${ES_PASS}" \
  --cacert "${CERTS_DIR}/ca/ca.crt" \
  -X POST "https://${ES_IP}:9200/_security/api_key" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "filebeat-wazuh",
    "role_descriptors": {
      "filebeat_writer": {
        "cluster": ["monitor", "read_ilm", "manage_index_templates", "manage_ingest_pipelines"],
        "index": [{
          "names": ["wazuh-alerts-*"],
          "privileges": ["create_index", "index", "create", "write"]
        }]
      }
    }
  }')

APIKEY_SURI=$(curl -s -u "elastic:${ES_PASS}" \
  --cacert "${CERTS_DIR}/ca/ca.crt" \
  -X POST "https://${ES_IP}:9200/_security/api_key" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "filebeat-suricata",
    "role_descriptors": {
      "filebeat_writer": {
        "cluster": ["monitor", "read_ilm", "manage_index_templates", "manage_ingest_pipelines"],
        "index": [{
          "names": ["suricata-eve-*"],
          "privileges": ["create_index", "index", "create", "write"]
        }]
      }
    }
  }')

# Encoder en base64 (format requis par Filebeat : id:api_key en base64)
WAZUH_ID=$(echo "$APIKEY_WAZUH" | jq -r '.id')
WAZUH_KEY=$(echo "$APIKEY_WAZUH" | jq -r '.api_key')
WAZUH_B64=$(echo -n "${WAZUH_ID}:${WAZUH_KEY}" | base64 -w 0)

SURI_ID=$(echo "$APIKEY_SURI" | jq -r '.id')
SURI_KEY=$(echo "$APIKEY_SURI" | jq -r '.api_key')
SURI_B64=$(echo -n "${SURI_ID}:${SURI_KEY}" | base64 -w 0)


cat > /vagrant/certs/filebeat_apikeys.env << EOF4
FILEBEAT_WAZUH_APIKEY=${WAZUH_ID}:${WAZUH_KEY}
FILEBEAT_SURICATA_APIKEY=${SURI_ID}:${SURI_KEY}
EOF4

chmod 600 /vagrant/certs/filebeat_apikeys.env

echo "API keys stockées dans /vagrant/certs/filebeat_apikeys.env"

echo "=== [TEMPLATES] Création index templates ==="
sleep 5
bash /vagrant/scripts/elk/create_templates.sh

echo ""
echo "════════════════════════════════════════════"
echo "INSTALLATION ELK TERMINÉE"
echo "Elasticsearch : https://${ES_IP}:9200"
echo "Kibana        : http://${ES_IP}:5601"
echo "User elastic  : ${ES_PASS}"
echo "CA distribué  : /vagrant/certs/ca.crt"
echo "════════════════════════════════════════════"