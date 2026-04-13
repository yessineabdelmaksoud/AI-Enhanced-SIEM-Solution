#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/wazuh-install.log) 2>&1

echo "=== [1/7] Mise à jour système ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

echo "=== [2/7] Dépendances ==="
apt-get install -y -qq \
  curl wget gnupg apt-transport-https \
  lsb-release ca-certificates \
  net-tools ufw openssl

echo "=== [3/7] Repo Wazuh 4.x ==="
install -d -m 0755 /usr/share/keyrings
rm -f /usr/share/keyrings/wazuh.gpg
curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
  | gpg --batch --yes --no-tty --dearmor -o /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
  > /etc/apt/sources.list.d/wazuh.list
apt-get update -qq

echo "=== [4/7] Installation Wazuh Manager ==="
apt-get install -y wazuh-manager

echo "=== [5/7] Certificat SSL pour wazuh-authd ==="
if [ ! -f /var/ossec/etc/sslmanager.cert ]; then
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /var/ossec/etc/sslmanager.key \
    -out /var/ossec/etc/sslmanager.cert \
    -subj "/CN=wazuh-manager" 2>/dev/null
fi
chown root:wazuh /var/ossec/etc/sslmanager.key /var/ossec/etc/sslmanager.cert
chmod 640 /var/ossec/etc/sslmanager.key /var/ossec/etc/sslmanager.cert

echo "=== [6/7] Configuration ossec.conf ==="
tee /var/ossec/etc/ossec.conf > /dev/null << 'OSSEC'
<ossec_config>

  <global>
    <jsonout_output>yes</jsonout_output>
    <alerts_log>yes</alerts_log>
    <logall>yes</logall>
    <logall_json>yes</logall_json>
    <email_notification>no</email_notification>
    <queue_size>131072</queue_size>
  </global>

  <alerts>
    <log_alert_level>3</log_alert_level>
    <email_alert_level>12</email_alert_level>
  </alerts>

  <auth>
    <disabled>no</disabled>
    <port>1515</port>
    <use_source_ip>no</use_source_ip>
    <purge>yes</purge>
    <use_password>no</use_password>
    <ssl_verify_host>no</ssl_verify_host>
    <ssl_manager_cert>etc/sslmanager.cert</ssl_manager_cert>
    <ssl_manager_key>etc/sslmanager.key</ssl_manager_key>
    <ssl_auto_negotiate>no</ssl_auto_negotiate>
  </auth>

  <remote>
    <connection>secure</connection>
    <port>1514</port>
    <protocol>tcp</protocol>
    <queue_size>131072</queue_size>
  </remote>

  <syscheck>
    <frequency>60</frequency>
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

  <command>
    <name>firewall-drop</name>
    <executable>firewall-drop</executable>
    <timeout_allowed>yes</timeout_allowed>
  </command>

  <active-response>
    <command>firewall-drop</command>
    <location>local</location>
    <rules_id>5763</rules_id>
    <timeout>600</timeout>
  </active-response>

  <ruleset>
    <decoder_dir>ruleset/decoders</decoder_dir>
    <rule_dir>ruleset/rules</rule_dir>
    <rule_exclude>0215-policy_rules.xml</rule_exclude>
    <list>etc/lists/audit-keys</list>
    <list>etc/lists/amazon/aws-eventnames</list>
    <list>etc/lists/security-eventchannel</list>
  </ruleset>

</ossec_config>
OSSEC

echo "=== [7/7] Firewall + Démarrage ==="
ufw allow 22/tcp
ufw allow 1514/tcp
ufw allow 1515/tcp
ufw --force enable

systemctl daemon-reload
systemctl enable wazuh-manager
systemctl restart wazuh-manager

sleep 5
sudo ss -tlnp | grep -E '1514|1515'

echo "=== INSTALLATION TERMINÉE ==="
systemctl status wazuh-manager --no-pager