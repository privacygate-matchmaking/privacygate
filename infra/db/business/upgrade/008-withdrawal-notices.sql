-- 탈퇴 안내 기록 + purge_member 가 안내 기록을 남기도록 교체 (새 DB 는 01·02 에 포함됨)
-- 실행: docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 < infra/db/business/upgrade/008-withdrawal-notices.sql
BEGIN;
CREATE TABLE IF NOT EXISTS withdrawal_notices (
    user_id               uuid PRIMARY KEY,
    by_staff              boolean NOT NULL,
    reason                text CHECK (char_length(reason) <= 200),
    withdrawn_at          timestamptz NOT NULL DEFAULT now(),
    account_delete_after  timestamptz NOT NULL
);
DROP FUNCTION IF EXISTS purge_member(uuid);
CREATE OR REPLACE FUNCTION purge_member(p_member uuid, p_notice_days int DEFAULT 30) RETURNS TABLE (storage_key text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_user uuid; v_by uuid; v_reason text;
BEGIN
    SELECT m.user_id, m.withdraw_requested_by, m.withdraw_reason INTO v_user, v_by, v_reason
      FROM members m WHERE m.member_id = p_member FOR UPDATE;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    RETURN QUERY SELECT e.storage_key FROM evidence_files e
                  WHERE (e.member_id = p_member OR e.submitted_by = v_user) AND e.storage_key IS NOT NULL;
    DELETE FROM evidence_reviews r USING evidence_files e
     WHERE r.file_id = e.file_id AND (e.member_id = p_member OR e.submitted_by = v_user);
    DELETE FROM evidence_files e WHERE e.member_id = p_member OR e.submitted_by = v_user;
    DELETE FROM intro_files f WHERE f.member_id = p_member
        OR f.consent_id IN (SELECT c.consent_id FROM consents c
                             WHERE c.member_id = p_member OR c.counterpart_member_id = p_member);
    DELETE FROM consents c WHERE c.member_id = p_member OR c.counterpart_member_id = p_member;
    DELETE FROM matches x WHERE x.member_id = p_member OR x.counterpart_member_id = p_member;
    DELETE FROM introductions i WHERE i.member_id = p_member OR i.counterpart_member_id = p_member;
    DELETE FROM assignments a WHERE a.member_id = p_member;
    DELETE FROM members m WHERE m.member_id = p_member;
    IF v_user IS NOT NULL THEN
        DELETE FROM sessions s WHERE s.user_id = v_user;
        DELETE FROM users u WHERE u.user_id = v_user AND u.role = 'member';
        -- 본인이 요청한 탈퇴면 by_staff = false (요청자 기록이 없으면 직원 처리로 본다)
        INSERT INTO withdrawal_notices (user_id, by_staff, reason, account_delete_after)
        VALUES (v_user, v_by IS DISTINCT FROM v_user,
                CASE WHEN v_by IS DISTINCT FROM v_user THEN v_reason END,
                now() + make_interval(days => GREATEST(p_notice_days, 0)))
        ON CONFLICT (user_id) DO UPDATE SET by_staff = EXCLUDED.by_staff, reason = EXCLUDED.reason,
               withdrawn_at = EXCLUDED.withdrawn_at, account_delete_after = EXCLUDED.account_delete_after;
    END IF;
END $$;
REVOKE ALL ON FUNCTION purge_member(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION purge_member(uuid, int) TO app_user;
GRANT SELECT, DELETE ON withdrawal_notices TO app_user;
COMMIT;
