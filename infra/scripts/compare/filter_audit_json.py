"""감사 JSON 로그(/var/log/matchmaking/*.json)에서 since 이후 줄만 출력 (컨테이너 안에서 실행)."""
import glob, json, sys
from datetime import datetime
since = datetime.fromisoformat(sys.argv[1])
for path in sorted(glob.glob('/var/log/matchmaking/*.json')):
    with open(path, encoding='utf-8') as f:
        for line in f:
            try:
                e = json.loads(line); ts = datetime.fromisoformat(e['ts'].replace('Z', '+00:00'))
            except (ValueError, KeyError):
                continue
            if ts >= since:
                sys.stdout.write(line if line.endswith('\n') else line + '\n')
