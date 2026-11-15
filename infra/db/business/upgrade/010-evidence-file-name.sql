-- 증빙 파일 이름: 서버가 정한 "회원코드(이름)_종류.확장자" (회원이 올린 파일 이름은 쓰지 않음)
-- 실행: docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 < infra/db/business/upgrade/010-evidence-file-name.sql
BEGIN;
ALTER TABLE evidence_files ADD COLUMN IF NOT EXISTS file_name text CHECK (char_length(file_name) <= 120);
-- 이미 제출된 증빙도 같은 형식으로 채운다 (사진은 원본 형식을 알 수 없어 .jpg 로 표시)
UPDATE evidence_files e
   SET file_name = m.pseudo_id || '(' || coalesce(m.name, '회원') || ')_' || e.kind || CASE WHEN e.kind = 'photo' THEN '.jpg' ELSE '.pdf' END
  FROM members m
 WHERE m.member_id = e.member_id AND e.file_name IS NULL;
COMMIT;
