#!/bin/bash
set -euo pipefail

source /vagrant/certs/es_credentials.env
CA_CERT="/etc/elasticsearch/certs/ca/ca.crt"

ES_CURL="curl -s -u ${ES_USER}:${ES_PASS} --cacert ${CA_CERT}"

echo "=== Ingest Pipeline : wazuh-normalize ==="
${ES_CURL} -X PUT "${ES_HOST}/_ingest/pipeline/wazuh-normalize" \
  -H "Content-Type: application/json" \
  -d '{
  "description": "Normalise les alertes Wazuh vers un modèle hybride ECS + champs metier",
  "processors": [
    {
      "rename": {
        "field": "rule.id",
        "target_field": "wazuh.rule_id",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "rule.level",
        "target_field": "wazuh.severity",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "rule.description",
        "target_field": "wazuh.rule_description",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "agent.name",
        "target_field": "wazuh.agent_name",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "agent.ip",
        "target_field": "wazuh.agent_ip",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "data.srcip",
        "target_field": "source.ip",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "data.dstip",
        "target_field": "destination.ip",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "data.srcport",
        "target_field": "source.port",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "data.dstport",
        "target_field": "destination.port",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "syscheck.path",
        "target_field": "file.path",
        "ignore_missing": true
      }
    },
    {
      "set": {
        "field": "event.dataset",
        "value": "wazuh.alert"
      }
    },
    {
      "set": {
        "field": "event.kind",
        "value": "alert"
      }
    },
    {
      "set": {
        "field": "event.category",
        "value": ["host","intrusion_detection"]
      }
    },
    {
      "set": {
        "field": "event.type",
        "value": ["info"]
      }
    },
    {
      "set": {
        "field": "source_engine",
        "value": "wazuh"
      }
    },
    {
      "set": {
        "field": "host.name",
        "copy_from": "wazuh.agent_name",
        "ignore_empty_value": true
      }
    },
    {
      "set": {
        "field": "observer.name",
        "value": "wazuh-manager"
      }
    },
    {
      "set": {
        "field": "observer.type",
        "value": "hids"
      }
    },
    {
      "date": {
        "field": "timestamp",
        "target_field": "@timestamp",
        "formats": ["ISO8601", "yyyy-MM-dd'\''T'\''HH:mm:ss.SSSZ"],
        "ignore_failure": true
      }
    },
    {
      "append": {
        "field": "related.ip",
        "value": "{{{source.ip}}}",
        "allow_duplicates": false,
        "ignore_failure": true
      }
    },
    {
      "append": {
        "field": "related.ip",
        "value": "{{{destination.ip}}}",
        "allow_duplicates": false,
        "ignore_failure": true
      }
    }
  ]
}'

echo ""
echo "=== Ingest Pipeline : suricata-normalize ==="
${ES_CURL} -X PUT "${ES_HOST}/_ingest/pipeline/suricata-normalize" \
  -H "Content-Type: application/json" \
  -d '{
  "description": "Normalise les alertes Suricata vers ECS + champs metier",
  "processors": [
    {
      "rename": {
        "field": "alert.signature_id",
        "target_field": "suricata.rule_id",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "alert.severity",
        "target_field": "suricata.severity",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "alert.signature",
        "target_field": "suricata.signature",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "alert.category",
        "target_field": "suricata.category",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "alert.action",
        "target_field": "suricata.action",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "alert.rev",
        "target_field": "suricata.rev",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "src_ip",
        "target_field": "source.ip",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "src_port",
        "target_field": "source.port",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "dest_ip",
        "target_field": "destination.ip",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "dest_port",
        "target_field": "destination.port",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "proto",
        "target_field": "network.transport",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "app_proto",
        "target_field": "network.protocol",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "community_id",
        "target_field": "network.community_id",
        "ignore_missing": true
      }
    },
    {
      "set": {
        "field": "event.dataset",
        "value": "suricata.alert"
      }
    },
    {
      "set": {
        "field": "event.kind",
        "value": "alert"
      }
    },
    {
      "set": {
        "field": "event.category",
        "value": ["network","intrusion_detection"]
      }
    },
    {
      "set": {
        "field": "event.type",
        "value": ["info"]
      }
    },
    {
      "set": {
        "field": "source_engine",
        "value": "suricata"
      }
    },
    {
      "set": {
        "field": "observer.name",
        "value": "vm-suri-01"
      }
    },
    {
      "set": {
        "field": "observer.type",
        "value": "nids"
      }
    },
    {
      "date": {
        "field": "timestamp",
        "target_field": "@timestamp",
        "formats": ["ISO8601", "yyyy-MM-dd'\''T'\''HH:mm:ss.SSSZ"],
        "ignore_failure": true
      }
    },
    {
      "append": {
        "field": "related.ip",
        "value": "{{{source.ip}}}",
        "allow_duplicates": false,
        "ignore_failure": true
      }
    },
    {
      "append": {
        "field": "related.ip",
        "value": "{{{destination.ip}}}",
        "allow_duplicates": false,
        "ignore_failure": true
      }
    }
  ]
}'

echo ""
echo "=== Index Template : wazuh-alerts ==="
${ES_CURL} -X PUT "${ES_HOST}/_index_template/wazuh-alerts-template" \
  -H "Content-Type: application/json" \
  -d '{
  "index_patterns": ["wazuh-alerts-*"],
  "priority": 100,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0,
      "index.refresh_interval": "10s"
    },
    "mappings": {
      "properties": {
        "@timestamp":             { "type": "date" },
        "timestamp":              { "type": "date" },
        "id":                     { "type": "keyword" },
        "source_engine":          { "type": "keyword" },

        "event.dataset":          { "type": "keyword" },
        "event.kind":             { "type": "keyword" },
        "event.category":         { "type": "keyword" },
        "event.type":             { "type": "keyword" },

        "wazuh.rule_id":          { "type": "keyword" },
        "wazuh.severity":         { "type": "integer" },
        "wazuh.rule_description": { "type": "text" },
        "wazuh.agent_name":       { "type": "keyword" },
        "wazuh.agent_ip":         { "type": "ip", "ignore_malformed": true },

        "rule.groups":            { "type": "keyword" },
        "decoder.name":           { "type": "keyword" },
        "location":               { "type": "keyword" },
        "manager.name":           { "type": "keyword" },

        "host.name":              { "type": "keyword" },
        "user.name":              { "type": "keyword" },

        "source.ip":              { "type": "ip", "ignore_malformed": true },
        "source.port":            { "type": "integer" },
        "destination.ip":         { "type": "ip", "ignore_malformed": true },
        "destination.port":       { "type": "integer" },
        "related.ip":             { "type": "ip", "ignore_malformed": true },

        "data.srcip":             { "type": "ip", "ignore_malformed": true },
        "data.dstip":             { "type": "ip", "ignore_malformed": true },
        "data.srcport":           { "type": "integer" },
        "data.dstport":           { "type": "integer" },

        "syscheck.path":          { "type": "keyword" },
        "syscheck.event":         { "type": "keyword" },
        "file.path":              { "type": "keyword" },

        "observer.name":          { "type": "keyword" },
        "observer.type":          { "type": "keyword" },

        "full_log":               { "type": "text" }
      }
    }
  }
}'

echo ""
echo "=== Index Template : suricata-eve ==="
${ES_CURL} -X PUT "${ES_HOST}/_index_template/suricata-eve-template" \
  -H "Content-Type: application/json" \
  -d '{
  "index_patterns": ["suricata-eve-*"],
  "priority": 100,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0,
      "index.refresh_interval": "10s"
    },
    "mappings": {
      "properties": {
        "@timestamp":            { "type": "date" },
        "timestamp":             { "type": "date" },
        "source_engine":         { "type": "keyword" },

        "event.dataset":         { "type": "keyword" },
        "event.kind":            { "type": "keyword" },
        "event.category":        { "type": "keyword" },
        "event.type":            { "type": "keyword" },

        "suricata.rule_id":      { "type": "keyword" },
        "suricata.severity":     { "type": "integer" },
        "suricata.signature":    { "type": "text" },
        "suricata.category":     { "type": "keyword" },
        "suricata.action":       { "type": "keyword" },
        "suricata.rev":          { "type": "integer" },
        "suricata.metadata":     { "type": "flattened" },

        "source.ip":             { "type": "ip", "ignore_malformed": true },
        "source.port":           { "type": "integer" },
        "source.bytes":          { "type": "long" },

        "destination.ip":        { "type": "ip", "ignore_malformed": true },
        "destination.port":      { "type": "integer" },
        "destination.bytes":     { "type": "long" },

        "network.transport":     { "type": "keyword" },
        "network.protocol":      { "type": "keyword" },
        "network.community_id":  { "type": "keyword" },
        "network.bytes":         { "type": "long" },

        "flow_id":               { "type": "keyword" },
        "host.name":             { "type": "keyword" },
        "observer.name":         { "type": "keyword" },
        "observer.type":         { "type": "keyword" },
        "related.ip":            { "type": "ip", "ignore_malformed": true }
      }
    }
  }
}'

echo ""
echo "=== Index Template : soc-ai-alerts ==="
${ES_CURL} -X PUT "${ES_HOST}/_index_template/soc-ai-alerts-template" \
  -H "Content-Type: application/json" \
  -d '{
  "index_patterns": ["soc-ai-alerts-*"],
  "priority": 100,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0,
      "index.refresh_interval": "10s"
    },
    "mappings": {
      "properties": {
        "@timestamp":                           { "type": "date" },
        "created_at":                           { "type": "date" },

        "incident_id":                          { "type": "keyword" },
        "group_id":                             { "type": "keyword" },
        "report_id":                            { "type": "keyword" },
        "chat_session_id":                      { "type": "keyword" },

        "dedup_key":                            { "type": "keyword" },
        "original_alert_id":                    { "type": "keyword" },
        "source_engine":                        { "type": "keyword" },
        "action_type":                          { "type": "keyword" },
        "status":                               { "type": "keyword" },

        "risk_score":                           { "type": "float" },

        "llm.model":                            { "type": "keyword" },
        "llm.latency_ms":                       { "type": "integer" },
        "llm.prompt_version":                   { "type": "keyword" },
        "llm.validation_status":                { "type": "keyword" },

        "context.event_count":                  { "type": "integer" },
        "context.window_start":                 { "type": "date" },
        "context.window_end":                   { "type": "date" },
        "context.source_indexes":               { "type": "keyword" },

        "source_alert.timestamp":               { "type": "date" },
        "source_alert.rule_id":                 { "type": "keyword" },
        "source_alert.agent_name":              { "type": "keyword" },
        "source_alert.source_ip":               { "type": "ip", "ignore_malformed": true },
        "source_alert.destination_ip":          { "type": "ip", "ignore_malformed": true },

        "timeline":                             { "type": "nested" },

        "enrichment.explanation":               { "type": "text" },
        "enrichment.severity_assessment":       { "type": "keyword" },
        "enrichment.false_positive_likelihood": { "type": "keyword" },
        "enrichment.investigation_steps":       { "type": "text" },
        "enrichment.key_iocs":                  { "type": "keyword" },
        "enrichment.immediate_actions":         { "type": "text" },
        "enrichment.long_term_recommendations": { "type": "text" }
      }
    }
  }
}'

echo ""
echo "=== Vérification templates ==="
${ES_CURL} "${ES_HOST}/_index_template?pretty" | jq "[.index_templates[].name]"

echo "=== TEMPLATES CRÉÉS ==="