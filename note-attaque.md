sudo nmap -sS -p 1-1000 --min-rate 500 192.168.56.51

sudo tail -f /var/log/suricata/eve.json | jq 'select(.event_type=="alert") | {time: .timestamp, sid: .alert.signature_id, msg: .alert.signature, src: .src_ip, dst: .dest_ip}'

sudo tail -f /var/ossec/logs/alerts/alerts.json | jq '{ip: .data.srcip, rule: .rule.description, level: .rule.level}'

echo -e "123456\npassword\nroot\nadmin" > test.txt
hydra -l root -P test.txt -t 4 ssh://192.168.56.51
