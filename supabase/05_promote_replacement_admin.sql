-- 적용 완료 / 일회성 기록: 변경된 운영자 계정 지정
-- 새 환경에서 무심코 재실행하지 마세요.

update public.profiles
set role = 'admin', status = 'approved', full_name = '모티프 운영팀'
where email = 'davidhan0307@gmail.com';
