-- 회원 프로필 확장: 생년월일·키·몸무게·학력·직군·직장·소개, 증빙 종류(학력/재직) (새 DB 는 01~03 에 포함됨)
-- 실행: docker compose exec -T business-db psql -U db_owner -d matchmaking_business -v ON_ERROR_STOP=1 < infra/db/business/upgrade/005-member-profile.sql
BEGIN;
ALTER TABLE members
  ADD COLUMN IF NOT EXISTS birth_date date,
  ADD COLUMN IF NOT EXISTS height_cm smallint CHECK (height_cm BETWEEN 120 AND 230),
  ADD COLUMN IF NOT EXISTS weight_kg smallint CHECK (weight_kg BETWEEN 30 AND 200),
  ADD COLUMN IF NOT EXISTS education_level text CHECK (education_level IN ('고졸', '전문대졸', '4년제 대졸', '대학원졸')),
  ADD COLUMN IF NOT EXISTS school text,
  ADD COLUMN IF NOT EXISTS major text,
  ADD COLUMN IF NOT EXISTS job_group text,
  ADD COLUMN IF NOT EXISTS company text,
  ADD COLUMN IF NOT EXISTS introduction text,
  ADD COLUMN IF NOT EXISTS education_verified boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS employment_verified boolean NOT NULL DEFAULT false;

-- 기존 값 옮기기 (생년은 1월 1일로, 직업은 직군으로)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'members' AND column_name = 'birth_year') THEN
    UPDATE members SET birth_date = make_date(birth_year, 1, 1) WHERE birth_date IS NULL AND birth_year IS NOT NULL;
    UPDATE members SET job_group = job WHERE job_group IS NULL;
    ALTER TABLE members DROP COLUMN birth_year, DROP COLUMN job;
  END IF;
END $$;

-- 시드 회원 프로필 (합성 데이터)
UPDATE members m SET birth_date = v.birth_date::date, height_cm = v.h, weight_kg = v.w,
       education_level = v.edu, school = v.school, major = v.major, job_group = v.jg, company = v.company,
       introduction = v.intro, education_verified = v.ev, employment_verified = v.mv
  FROM (VALUES
    ('M-001','1994-03-12',178,72,'4년제 대졸','한국가상대학교','컴퓨터공학','IT·개발','이음전자','주말에는 등산과 사진 찍기를 즐겨요.',true,true),
    ('M-002','1995-07-21',165,54,'대학원졸','가상교육대학원','교육학','교육','가상초등학교','책과 클래식 음악을 좋아합니다.',true,false),
    ('M-003','1993-11-02',172,63,'4년제 대졸','미래가상대학교','경영학','금융','이음은행','여행과 요리가 취미입니다.',false,false),
    ('M-004','1992-01-30',168,58,'전문대졸','이음가상전문대','간호학','의료','이음병원','반려견과 산책하는 시간이 제일 좋아요.',true,true),
    ('M-005','1996-05-05',181,77,'4년제 대졸','한빛가상대학교','회계학','회계·재무','이음회계법인','아침 러닝을 꾸준히 하고 있어요.',true,false),
    ('M-006','1991-09-14',175,70,'고졸','가상고등학교',NULL,'공공','이음시청','캠핑과 낚시를 좋아합니다.',true,true),
    ('M-007','1997-12-24',160,50,'4년제 대졸','가상미술대학교','시각디자인','디자인','이음스튜디오','전시회 보러 다니는 걸 좋아해요.',false,false),
    ('M-008','1990-04-18',183,80,'대학원졸','가상약학대학원','약학','의료','이음약국','요즘은 테니스를 배우고 있어요.',true,true)
  ) AS v(code, birth_date, h, w, edu, school, major, jg, company, intro, ev, mv)
 WHERE m.pseudo_id = v.code AND m.height_cm IS NULL;   -- 아직 프로필을 안 채운 시드 회원만
-- 닉네임 컬럼은 쓰지 않는다 (이전 버전에서 만들었다면 삭제)
ALTER TABLE members DROP COLUMN IF EXISTS nickname;

ALTER TABLE evidence_files ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'education'
  CHECK (kind IN ('education', 'employment'));

GRANT UPDATE (birth_date, height_cm, weight_kg, education_level, school, major, job_group, company, introduction,
              education_verified, employment_verified, name, contact_phone, contact_email, status, withdrawn_at) ON members TO app_user;
COMMIT;
