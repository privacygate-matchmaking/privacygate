-- 합성 시험 데이터. user_id 는 infra/keycloak/realm-matchmaking.json 의 사용자 id 와 같다.
INSERT INTO users (user_id, pseudo_id, display_name, role) VALUES
  ('11111111-1111-4111-8111-111111111101', 'S-C01', 'counselor_a',  'counselor'),
  ('11111111-1111-4111-8111-111111111102', 'S-D01', 'data_admin',   'data_admin'),
  ('11111111-1111-4111-8111-111111111103', 'S-P01', 'approver',     'approver'),
  ('22222222-2222-4222-8222-222222222201', 'M-B01', 'member_b',     'member');

INSERT INTO members (member_id, user_id, pseudo_id, name, birth_year, job, contact_phone, contact_email) VALUES
  ('bbbbbbbb-0000-4000-8000-000000000001', NULL, 'M-001', '가상회원01', 1994, '연구원',   '010-0000-0001', 'm01@example.test'),
  ('bbbbbbbb-0000-4000-8000-000000000002', NULL, 'M-002', '가상회원02', 1995, '교사',     '010-0000-0002', 'm02@example.test'),
  ('bbbbbbbb-0000-4000-8000-000000000003', '22222222-2222-4222-8222-222222222201',
                                                 'M-003', '가상회원03', 1993, '개발자',   '010-0000-0003', 'm03@example.test'),
  ('bbbbbbbb-0000-4000-8000-000000000004', NULL, 'M-004', '가상회원04', 1992, '간호사',   '010-0000-0004', 'm04@example.test'),
  ('bbbbbbbb-0000-4000-8000-000000000005', NULL, 'M-005', '가상회원05', 1996, '회계사',   '010-0000-0005', 'm05@example.test'),
  ('bbbbbbbb-0000-4000-8000-000000000006', NULL, 'M-006', '가상회원06', 1991, '공무원',   '010-0000-0006', 'm06@example.test'),
  ('bbbbbbbb-0000-4000-8000-000000000007', NULL, 'M-007', '가상회원07', 1997, '디자이너', '010-0000-0007', 'm07@example.test'),
  ('bbbbbbbb-0000-4000-8000-000000000008', NULL, 'M-008', '가상회원08', 1990, '약사',     '010-0000-0008', 'm08@example.test');

-- counselor_a 는 회원 1~3 만 담당 (member_b = 회원 3)
INSERT INTO assignments (user_id, member_id) VALUES
  ('11111111-1111-4111-8111-111111111101', 'bbbbbbbb-0000-4000-8000-000000000001'),
  ('11111111-1111-4111-8111-111111111101', 'bbbbbbbb-0000-4000-8000-000000000002'),
  ('11111111-1111-4111-8111-111111111101', 'bbbbbbbb-0000-4000-8000-000000000003');

-- 소개 관계: member_b(회원 3)는 회원 1·2 와 서로 소개됨 (양방향으로 저장)
INSERT INTO introductions (member_id, counterpart_member_id) VALUES
  ('bbbbbbbb-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000003'),
  ('bbbbbbbb-0000-4000-8000-000000000003', 'bbbbbbbb-0000-4000-8000-000000000001'),
  ('bbbbbbbb-0000-4000-8000-000000000002', 'bbbbbbbb-0000-4000-8000-000000000003'),
  ('bbbbbbbb-0000-4000-8000-000000000003', 'bbbbbbbb-0000-4000-8000-000000000002');

-- 회원 1 이 member_b(회원 3)에게 프로필 공개 동의 (30일)
INSERT INTO consents (member_id, counterpart_member_id, item, purpose, expires_at) VALUES
  ('bbbbbbbb-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000003',
   'profile', 'introduction', now() + interval '30 days');
