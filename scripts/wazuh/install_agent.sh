#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/wazuh-agent-install.log) 2>&1

WAZUH_MANAGER_IP="192.168.56.10"
AGENT_NAME="$(hostname)"

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

echo "=== [3/6] Repo Wazuh 4.x ==="
install -d -m 0755 /usr/share/keyrings
rm -f /usr/share/keyrings/wazuh.gpg
curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
  | gpg --batch --yes --no-tty --dearmor -o /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
  > /etc/apt/sources.list.d/wazuh.list
apt-get update -qq

echo "=== [4/6] Installation Wazuh Agent ==="
WAZUH_MANAGER="${WAZUH_MANAGER_IP}" \
WAZUH_AGENT_NAME="${AGENT_NAME}" \
apt-get install -y wazuh-agent

echo "=== [5/6] Configuration ossec.conf ==="
tee /var/ossec/etc/ossec.conf > /dev/null << 'AGENT_CONF'
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
    <directories check_all="yes" realtime="yes">/etc/passwd,/etc/shadow,/etc/sudoers</directories>
    <directories check_all="yes" realtime="yes">/etc/ssh/sshd_config</directories>
    <ignore>/etc/mtab</ignore>
    <ignore>/etc/hosts.deny</ignore>
  </syscheck>

  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/syslog</location>
  </localfile>
  <localfile>
    <log_format>audit</log_format>
    <location>/var/log/audit/audit.log</location>
  </localfile>

</ossec_config>
AGENT_CONF

echo "=== [5b/6] Règles auditd ==="
tee /etc/audit/rules.d/wazuh.rules > /dev/null << 'EOF'
-w /etc/passwd -p wa -k passwd_changes
-w /etc/shadow -p wa -k shadow_changes
-w /etc/sudoers -p wa -k sudoers_changes
-a exit,always -F arch=b64 -S execve -k exec_commands
EOF
augenrules --load
systemctl enable auditd
systemctl restart auditd

echo "=== [6/6] Firewall + Démarrage ==="
ufw allow 22/tcp
ufw --force enable

systemctl daemon-reload
systemctl enable wazuh-agent
systemctl restart wazuh-agent

sleep 5
echo "=== AGENT INSTALLÉ : ${AGENT_NAME} → ${WAZUH_MANAGER_IP} ==="
systemctl status wazuh-agent --no-pager