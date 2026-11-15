"""Wazuh 경보(alerts.json)에서 since 이후 privacygate 그룹 경보만 출력 (manager 컨테이너 안에서 실행)."""
import json, sys
from datetime import datetime
since = datetime.fromisoformat(sys.argv[1])
with open('/var/ossec/logs/alerts/alerts.json', encoding='utf-8', errors='replace') as f:
    for line in f:
        try:
            a = json.loads(line)
            ts = datetime.strptime(a['timestamp'], '%Y-%m-%dT%H:%M:%S.%f%z')
        except (ValueError, KeyError):
            continue
        if ts >= since and 'privacygate' in a.get('rule', {}).get('groups', []) and not a.get('data', {}).get('lab_fixture'):
            keep = {'timestamp': a['timestamp'], 'rule_id': a['rule'].get('id'), 'level': a['rule'].get('level'),
                    'description': a['rule'].get('description'), 'data': a.get('data', {})}
            sys.stdout.write(json.dumps(keep, ensure_ascii=False) + '\n')
