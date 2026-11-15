-- 합성 발급대장 채우기: 모든 회원(시드 + 이후 등록 회원)의 시험용 문서 발급번호를 등록한다.
-- 실제 기관 연동이 아니라, doc-inspector 가 읽은 발급번호의 진위 판단(대장 대조)을 시험하기 위한 합성 자료다.
CREATE OR REPLACE FUNCTION register_documents_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM register_member_documents(NEW.member_id);
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS members_register_documents ON members;
CREATE TRIGGER members_register_documents
    AFTER INSERT ON members
    FOR EACH ROW EXECUTE FUNCTION register_documents_trigger();

DO $$ BEGIN PERFORM register_member_documents(member_id) FROM members; END $$;
