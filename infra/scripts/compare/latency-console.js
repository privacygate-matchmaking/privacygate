/* PrivacyGate 통제 지연 측정 — 브라우저 개발자도구(Console)에 붙여 넣는다 (baseline·enforce 에서 같은 코드).
 * 정상 요청(허용되는 요청)만 순서대로 N번 보내 응답 시간 p50·p95·최대를 잰다. 공격 요청은 보내지 않는다
 * (거부 요청을 반복하면 자동 임시 잠금이 걸린다).
 *   - 직원 화면 탭(로그인한 상담 직원·총관리자): GET /api/me, GET /api/members
 *       → 세션·역할·임시 잠금 확인 + 업무 DB 조회
 *   - 회원 화면 탭(승인 자료를 받은 회원): GET /api/me/status, GET /api/me/deliveries/{id}/download (대조군 정상 다운로드)
 *       → 외부 → 중계 → 내부 회원 상태 확인 + 승인·동의·무결성·파일 연결 검사
 * 결과: pg-evidence-latency-<직원|회원>-<모드>.json 으로 내려받아지고, collect-evidence.sh 가 증거 폴더로 옮긴다.
 * 토큰·쿠키·응답 본문은 기록하지 않는다 (상태 코드와 시간만). */
(async (N = 30) => {
  const pct = (arr, p) => { const s = [...arr].sort((a, b) => a - b); return +s[Math.min(s.length - 1, Math.ceil(p / 100 * s.length) - 1)].toFixed(1); };
  const me = await (await fetch('/api/me', {credentials: 'same-origin'})).json();
  const staff = !!me.role && me.role !== 'member';
  const targets = [];
  if (staff) {
    targets.push(['GET /api/me', '/api/me'], ['GET /api/members', '/api/members']);
  } else {
    targets.push(['GET /api/me/status', '/api/me/status']);
    const list = await (await fetch('/api/me/deliveries', {credentials: 'same-origin'})).json();
    const d = (list.items || []).find(x => x.request_status === 'approved');
    if (d) targets.push(['GET /api/me/deliveries/{id}/download', `/api/me/deliveries/${d.delivery_id}/download`]);
    else console.warn('승인된 자료가 없어 다운로드 측정은 건너뜁니다.');
  }
  const out = {scenario: 'latency', side: staff ? 'staff' : 'member', gate_mode: me.gate_mode || '(회원 화면은 모드 표시 없음)',
               n: N, started_at: new Date().toISOString(), user_agent: navigator.userAgent, results: []};
  for (const [label, url] of targets) {
    await fetch(url, {credentials: 'same-origin'});            // 예열 1회 (연결·캐시)
    const ms = [], codes = {};
    for (let i = 0; i < N; i++) {
      const t0 = performance.now();
      const r = await fetch(url, {credentials: 'same-origin', cache: 'no-store'});
      await r.arrayBuffer();
      ms.push(performance.now() - t0);
      codes[r.status] = (codes[r.status] || 0) + 1;
    }
    out.results.push({request: label, status_counts: codes, p50_ms: pct(ms, 50), p95_ms: pct(ms, 95),
                      max_ms: +Math.max(...ms).toFixed(1), mean_ms: +(ms.reduce((a, b) => a + b, 0) / ms.length).toFixed(1)});
  }
  const mode = staff ? me.gate_mode : (prompt('이 측정의 모드를 입력하세요 (baseline 또는 enforce)', 'enforce') || 'unknown');
  out.gate_mode = mode;
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([JSON.stringify(out, null, 2)], {type: 'application/json'}));
  a.download = `pg-evidence-latency-${out.side}-${mode}.json`; a.click();
  console.table(out.results.map(r => ({요청: r.request, 상태: JSON.stringify(r.status_counts), p50: r.p50_ms, p95: r.p95_ms, 최대: r.max_ms})));
})();
