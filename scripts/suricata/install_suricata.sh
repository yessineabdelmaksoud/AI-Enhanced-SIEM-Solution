#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/suricata-install.log) 2>&1

WAZUH_MANAGER_IP="192.168.56.10"
MONITOR_IFACE="eth1"   # interface private_network Vagrant = eth1

echo "=== [1/6] Mise à jour système ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

echo "=== [2/6] Dépendances ==="
apt-get install -y -qq \
  curl wget gnupg apt-transport-https \
  lsb-release ca-certificates \
  net-tools ufw \
  auditd audispd-plugins

echo "=== [3/6] Installation Suricata ==="
add-apt-repository -y ppa:oisf/suricata-stable
apt-get update -qq
apt-get install -y suricata

echo "=== [4/6] Configuration Suricata ==="
cat > /etc/suricata/suricata.yaml << SURICATA_CONF
%YAML 1.1
---
vars:
  address-groups:
    HOME_NET: "[192.168.56.0/24]"
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
    VXLAN_PORTS: 4789
    TEREDO_PORTS: 3544

default-log-dir: /var/log/suricata/

stats:
  enabled: yes
  interval: 8

outputs:
  - eve-log:
      enabled: yes
      filetype: regular
      filename: eve.json
      types:
        - alert:
            payload: yes
            payload-buffer-size: 4kb
            payload-printable: yes
            packet: yes
            metadata: yes
            http-body: yes
            http-body-printable: yes
            tagged-packets: yes
        - http:
            extended: yes
        - dns:
            query: yes
            answer: yes
        - tls:
            extended: yes
        - files:
            force-magic: no
        - smtp: {}
        - ssh: {}
        - stats:
            totals: yes
            threads: no
            deltas: no
        - flow: {}

  - fast:
      enabled: yes
      filename: fast.log
      append: yes

af-packet:
  - interface: ${MONITOR_IFACE}
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
    use-mmap: yes
    tpacket-v3: yes

detect:
  profile: medium
  custom-values:
    toclient-groups: 3
    toserver-groups: 25
  sgh-mpm-context: auto
  inspection-recursion-limit: 3000

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

logging:
  default-log-level: notice
  outputs:
    - console:
        enabled: no
    - file:
        enabled: yes
        level: info
        filename: /var/log/suricata/suricata.log
SURICATA_CONF

echo "=== [5/6] Wazuh Agent sur VM-SURI-01 ==="
install -d -m 0755 /usr/share/keyrings
rm -f /usr/share/keyrings/wazuh.gpg
curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
  | gpg --batch --yes --no-tty --dearmor -o /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
  > /etc/apt/sources.list.d/wazuh.list
apt-get update -qq

WAZUH_MANAGER="${WAZUH_MANAGER_IP}" \
WAZUH_AGENT_NAME="vm-suri-01" \
apt-get install -y wazuh-agent

# Config agent — lit eve.json de Suricata
cat > /var/ossec/etc/ossec.conf << 'AGENT_CONF'
<ossec_config>

  <client>
    <server>
      <address>192.168.56.10</address>
      <port>1514</port>
      <protocol>tcp</protocol>
    </server>
    <enrollment>
      <enabled>yes</enabled>
      <manager_address>192.168.56.10</manager_address>
      <port>1515</port>
    </enrollment>
  </client>

  <syscheck>
    <frequency>300</frequency>
    <scan_on_start>yes</scan_on_start>
    <alert_new_files>yes</alert_new_files>
    <directories check_all="yes" realtime="yes">/etc/suricata</directories>
    <ignore>/etc/mtab</ignore>
  </syscheck>

  <!-- Suricata eve.json — format JSON natif Wazuh -->
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/suricata/eve.json</location>
    <label key="source">suricata</label>
  </localfile>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/syslog</location>
  </localfile>

</ossec_config>
AGENT_CONF

# Permissions — wazuh-agent doit lire eve.json
usermod -aG suricata wazuh 2>/dev/null || true
chmod 640 /var/log/suricata/eve.json 2>/dev/null || true
chown suricata:suricata /var/log/suricata/ 2>/dev/null || true

echo "=== [6/6] Démarrage ==="
ufw allow 22/tcp
ufw --force enable

# Suricata en mode IDS sur l'interface interne
systemctl enable suricata
systemctl start suricata

systemctl daemon-reload
systemctl enable wazuh-agent
systemctl start wazuh-agent

echo "=== SURICATA + AGENT INSTALLÉS ==="
systemctl status suricata --no-pager
systemctl status wazuh-agent --no-pager