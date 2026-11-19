"""두 증거 폴더(baseline, enforce)를 비교해 report.md 를 만든다 (표준 라이브러리만 사용).
   python3 infra/scripts/compare/make-report.py evidence/<시각>-baseline evidence/<시각>-enforce
"""
import csv, json, sys
from collections import Counter
from pathlib import Path


def load_json(path):
    try: return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError): return None


def rows(path):
    try:
        with path.open(encoding='utf-8') as f: return list(csv.DictReader(f))
    except OSError: return []


def jsonl(path):
    out = []
    try:
        for line in path.read_text(encoding='utf-8').splitlines():
            try: out.append(json.loads(line))
            except ValueError: pass
    except OSError: pass
    return out


# 공격 판정과 관련된 규칙만 표에 싣는다 (나머지는 일반 업무 기록 건수로만 표시)
KEY_RULES = {'100110', '100111', '100112', '100120', '100130', '100131', '100132', '100150', '100151', '100152'}


def summarize(folder):
    d = Path(folder)
    a1 = next((load_json(p) for p in d.glob('pg-evidence-attack1-*.json')), None)
    a2 = next((load_json(p) for p in d.glob('pg-evidence-attack2-*.json') if not p.name.endswith(('-received.csv', '-received.json'))), None)
    internal, transfer = rows(d / 'audit-internal.csv'), rows(d / 'audit-transfer.csv')
    exports = rows(d / 'member-exports.csv')
    alerts = [a for a in jsonl(d / 'wazuh-alerts.jsonl') if 'rule_id' in a]
    wazuh_error = next((a['error'] for a in jsonl(d / 'wazuh-alerts.jsonl') if 'error' in a), None)
    att1 = (a1 or {}).get('attempts', [])
    a1_source = '브라우저 응답 기록'
    if not att1:
        # 브라우저 기록이 없으면 같은 요청의 서버 감사 로그로 대신한다 (허용=201, 거부=403).
        a1_source = '감사 로그(브라우저 기록 없음)'
        regs = [r for r in internal if r['action'].startswith('POST /api/member-exports/') and r['action'].endswith('/transfer-files')]
        for i, r in enumerate(x for x in internal if x['action'] == 'POST /api/admin/member-exports'):
            ok = r['result'] == 'allow'
            att1.append({'status': 201 if ok else 403, 'trace_id': r['trace_id'],
                         'body': {'row_count': int(exports[i]['row_count'])} if ok and i < len(exports) else {},
                         **({'transfer': {'status': 201 if regs[i]['result'] == 'allow' else 403,
                                          'body': {'file_id': exports[i]['transfer_file_id']}}} if ok and i < len(regs) and i < len(exports) else {})})
    s = {
        'a1_source': a1_source,
        'mode': (a1 or a2 or {}).get('gate_mode', '?'),
        'a1_status': [x['status'] for x in att1],
        'a1_rows': next((x['body'].get('row_count') for x in att1 if x['status'] == 201 and x.get('body')), None),
        'a1_transfer': next((x['transfer'] for x in att1 if x.get('transfer')), None),
        'a1_audit': Counter(f"{r['result']}:{r['reason'] or '-'}" for r in internal if r['action'] == 'POST /api/admin/member-exports'),
        'exports': [(r['created_by'], r['role'], r['row_count'], r['transfer_file_id'] or '-') for r in exports],
        'a2': (a2 or {}).get('attack'), 'a2_control': (a2 or {}).get('control'),
        'a2_audit': Counter(f"{r['result']}:{r['reason'] or '-'}" for r in transfer if 'download' in r['action']),
        'alerts': Counter(f"{a['rule_id']} {a['description']}" for a in alerts if a['rule_id'] in KEY_RULES),
        'other_alerts': sum(1 for a in alerts if a['rule_id'] not in KEY_RULES), 'wazuh_error': wazuh_error,
        'trace_ids': [x['trace_id'] for x in att1] + [x for x in [((a2 or {}).get('attack') or {}).get('trace_id')] if x],
    }
    incidents = [r for r in rows(d / 'security-incidents.csv') if r.get('kind')]
    s['incidents'] = [(r['kind'], r['subject_code'], '차단' if r['blocked'] in ('t', 'true', 'True') else '통과',
                       int(r['occurrences'] or 0), bool(r['auto_locked_until'])) for r in incidents]
    s['latency'] = [x for p in sorted(d.glob('pg-evidence-latency-*.json')) for x in [load_json(p)] if x]
    s['a1_leak'] = any(x == 201 for x in s['a1_status'])
    s['a2_leak'] = bool(s['a2'] and s['a2']['status'] == 200 and s['a2'].get('csv_rows'))
    return s


def fmt_counter(c): return ', '.join(f'{k} ×{v}' for k, v in c.items()) or '없음'


KIND_KO = {'unauthorized_export': '권한 밖 내보내기', 'approval_mismatch': '승인 외 자료 요청', 'repeated_denials': '역할 밖 요청 반복'}


def fmt_incidents(items):
    if not items: return '없음 (또는 upgrade/014 미적용)'
    return ', '.join(f"{KIND_KO.get(k, k)}({who}, {res}, {n}회{', 자동 잠금' if locked else ''})" for k, who, res, n, locked in items)


def latency_table(base, enf):
    def index(items):
        return {(x.get('side'), r['request']): r for x in items for r in x.get('results', [])}
    b, e = index(base), index(enf)
    keys = sorted(set(b) | set(e))
    if not keys: return ['측정 기록 없음 (선택 항목).', '']
    out = ['| 요청 | baseline p50 / p95 (ms) | enforce p50 / p95 (ms) | p50 차이 |', '|---|---|---|---|']
    for k in keys:
        x, y = b.get(k), e.get(k)
        cell = lambda r: f"{r['p50_ms']} / {r['p95_ms']}" if r else '-'
        diff = f"{y['p50_ms'] - x['p50_ms']:+.1f}" if x and y else '-'
        out.append(f"| {k[1]} ({'직원' if k[0] == 'staff' else '회원'}) | {cell(x)} | {cell(y)} | {diff} |")
    return out + ['', '- 같은 PC·같은 브라우저에서 정상 요청을 순서대로 N번 보낸 값이다. 네트워크(Funnel) 상태에 따라 달라지므로 차이의 크기만 참고한다.', '']


def main(base, enf):
    b, e = summarize(base), summarize(enf)
    def a2(s):
        x = s['a2']
        if not x: return '기록 없음'
        return f"HTTP {x['status']} · {x.get('content_type') or '-'} · " + (f"CSV {x['csv_rows']}행 반환" if x.get('csv_rows') else (x.get('error') or {}).get('code', '자료 없음') if isinstance(x.get('error'), dict) else str(x.get('error')))
    lines = [
        '# PrivacyGate 최종 보안 비교 시연 결과', '',
        f'- 취약 비교 버전 증거: `{base}`', f'- 보안 적용 버전 증거: `{enf}`',
        '- 두 버전에 브라우저에서 같은 요청 코드(`attack-console.js`)를 그대로 실행했다. 모든 데이터는 합성 데이터다.', '',
        '## 요약', '',
        '| 항목 | 취약 비교(baseline) | 보안 적용(enforce) |', '|---|---|---|',
        f"| 확인된 모드 (/api/me) | {b['mode']} | {e['mode']} |",
        f"| ① 상담 직원의 전체 회원 내보내기 응답 | {', '.join(map(str, b['a1_status'])) or '-'} ({b['a1_source']}) | {', '.join(map(str, e['a1_status'])) or '-'} ({e['a1_source']}) |",
        f"| ① 실제 생성된 내보내기 파일 | {len(b['exports'])}건 {b['exports'][:1]} | {len(e['exports'])}건 |",
        f"| ① 중계 등록 | {(b['a1_transfer'] or {}).get('status', '-')} {((b['a1_transfer'] or {}).get('body') or {}).get('scan_status', '')} | {(e['a1_transfer'] or {}).get('status', '-')} |",
        f"| ② 정상 다운로드(대조군) | HTTP {(b['a2_control'] or {}).get('status', '-')} | HTTP {(e['a2_control'] or {}).get('status', '-')} |",
        f"| ② file_id 바꿔치기 응답 | {a2(b)} | {a2(e)} |",
        f"| 감사 로그 ① (내부) | {fmt_counter(b['a1_audit'])} | {fmt_counter(e['a1_audit'])} |",
        f"| 감사 로그 ② (중계) | {fmt_counter(b['a2_audit'])} | {fmt_counter(e['a2_audit'])} |",
        f"| Wazuh 공격 관련 경보 | {b['wazuh_error'] or fmt_counter(b['alerts'])} | {e['wazuh_error'] or fmt_counter(e['alerts'])} |",
        f"| Wazuh 일반 업무 기록 | {b['other_alerts']}건 | {e['other_alerts']}건 |",
        f"| 판정 | ①{'유출' if b['a1_leak'] else '차단'} · ②{'유출' if b['a2_leak'] else '차단'} | ①{'유출' if e['a1_leak'] else '차단'} · ②{'유출' if e['a2_leak'] else '차단'} |",
        f"| 사후 대응: 보안 사건 | {fmt_incidents(b['incidents'])} | {fmt_incidents(e['incidents'])} |",
        '', '## 통제 지연 (정상 요청 응답 시간, latency-console.js)', '',
        *latency_table(b['latency'], e['latency']),
        '', '## 판정 기준', '',
        '- 유출/차단은 **API 응답과 실제 반환·생성된 파일**로 판정한다. Wazuh 경보는 탐지 증거이며 그것만으로 차단 성공을 판정하지 않는다.',
        '- baseline 은 공격 ①②가 노리는 통제 2개(관리자 내보내기 역할 검사, 다운로드의 요청 file_id ↔ 승인 파일 연결 검사)만 끈 시연용 모드다. 로그인·세션·CSRF·승인·동의·만료·무결성 검사는 두 모드 모두 동작한다.',
        '', '## 추적번호 (같은 요청의 서비스별 기록을 찾을 때)', '',
        f"- baseline: {', '.join(t for t in b['trace_ids'] if t)}", f"- enforce: {', '.join(t for t in e['trace_ids'] if t)}", '',
    ]
    report = '\n'.join(lines)
    out = Path(enf).parent / 'report.md'
    out.write_text(report, encoding='utf-8')
    print(report); print(f'\n저장: {out}')


if __name__ == '__main__':
    if len(sys.argv) != 3: sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
