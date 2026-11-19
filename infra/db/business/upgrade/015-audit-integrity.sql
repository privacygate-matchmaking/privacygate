-- 감사 로그 위변조 방지 (새 DB 는 10-audit-integrity.sql 에 포함)
-- 실행: docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 < infra/db/business/upgrade/015-audit-integrity.sql
BEGIN;
CREATE OR REPLACE FUNCTION audit_log_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND current_setting('privacygate.audit_purge', true) = 'on'
       AND OLD.ts < now() - make_interval(days => current_setting('privacygate.audit_retention_days', true)::int) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'audit_log is append-only (%)', TG_OP;
END $$;
DROP TRIGGER IF EXISTS audit_log_no_update ON audit_log;
CREATE TRIGGER audit_log_no_update BEFORE UPDATE OR DELETE ON audit_log FOR EACH ROW EXECUTE FUNCTION audit_log_append_only();
DROP TRIGGER IF EXISTS audit_log_no_truncate ON audit_log;
CREATE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON audit_log FOR EACH STATEMENT EXECUTE FUNCTION audit_log_append_only();

-- 보관기간 지난 감사 행 삭제: SELECT purge_audit_log(365);  (365일 미만은 거부)
CREATE OR REPLACE FUNCTION purge_audit_log(p_days int DEFAULT 365) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    IF p_days < 365 THEN RAISE EXCEPTION 'retention must be >= 365 days'; END IF;
    PERFORM set_config('privacygate.audit_purge', 'on', true);
    PERFORM set_config('privacygate.audit_retention_days', p_days::text, true);
    DELETE FROM audit_log WHERE ts < now() - make_interval(days => p_days);
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;
REVOKE ALL ON FUNCTION purge_audit_log(int) FROM PUBLIC;
COMMIT;
