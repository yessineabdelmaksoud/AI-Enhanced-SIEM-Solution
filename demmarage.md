Ordre de démarrage Vagrant obligatoire

# 1. ELK en premier — génère le CA et les API keys
vagrant up elk

# 2. Wazuh — attend /vagrant/certs/ca.crt avant de lancer Filebeat
vagrant up wazuh

# 3. Suricata — idem
vagrant up suricata

# 4. Endpoints
vagrant up endp01 endp02

# 5. AI — plus tard
vagrant up ai

Points de vérification post-déploiement

# Depuis VM-ELK-01
curl -sk -u elastic:SocSiem2024! \
  --cacert /etc/elasticsearch/certs/ca/ca.crt \
  https://192.168.56.20:9200/_cat/indices?v

# Résultat attendu après quelques minutes :
# wazuh-alerts-YYYY.MM.DD    green  1  0
# suricata-eve-YYYY.MM.DD    green  1  0

# Vérifier données Wazuh
curl -sk -u elastic:SocSiem2024! \
  --cacert /etc/elasticsearch/certs/ca/ca.crt \
  "https://192.168.56.20:9200/wazuh-alerts-*/_count"

# Vérifier données Suricata
curl -sk -u elastic:SocSiem2024! \
  --cacert /etc/elasticsearch/certs/ca/ca.crt \
  "https://192.168.56.20:9200/suricata-eve-*/_count"