#!/bin/bash
# 합성 회원을 무작위 값으로 N명(기본 1) 추가한다 (학력·재직 증빙은 미확인 상태).
# 회원 코드(A-011, A-012 …)는 DB 가 자동 발급한다. 담당 상담 직원은 DB 트리거가 무작위로 배정한다.
# 사용: ./infra/scripts/add-member.sh [N]   (privacygate 폴더에서, business-db 가 실행 중일 때)
set -euo pipefail
cd "$(dirname "$0")/../.."
n="${1:-1}"
docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 -v n="$n" <<'SQL'
INSERT INTO members (name, birth_date, height_cm, weight_kg, education_level,
                     job_group, introduction, contact_phone, contact_email)
SELECT '가상회원-' || code,
       date '1985-01-01' + floor(random() * 15 * 365)::int,
       155 + floor(random() * 30)::int,
       45 + floor(random() * 35)::int,
       (ARRAY['고졸','전문대졸','4년제 대졸','대학원졸'])[1 + floor(random() * 4)::int],
       (ARRAY['IT·개발','교육','의료','금융','공공','디자인','회계·재무','연구'])[1 + floor(random() * 8)::int],
       '가상 회원 소개입니다.',
       '010-0000-' || lpad(floor(random() * 10000)::text, 4, '0'),
       'm' || lower(code) || '@example.test'
  FROM (SELECT upper(substr(md5(random()::text), 1, 6)) AS code FROM generate_series(1, :n)) g;
-- 방금 추가한 회원과 자동 배정된 담당자
SELECT m.pseudo_id AS 회원, m.job_group AS 직군, u.display_name AS 담당
  FROM members m JOIN assignments a ON a.member_id = m.member_id JOIN users u ON u.user_id = a.user_id
 ORDER BY m.created_at DESC, m.pseudo_id LIMIT :n;
SQL
