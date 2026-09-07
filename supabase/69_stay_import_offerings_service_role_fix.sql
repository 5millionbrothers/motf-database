-- 숙소 자동 등록 API가 객실 행을 생성하고 실패 시 정리할 수 있도록 권한을 보강합니다.
-- service_role은 RLS를 우회하지만 명시적으로 회수된 테이블 권한까지 자동 복구하지는 않습니다.

grant usage on schema public to service_role;
grant select, insert, update, delete on table public.offerings to service_role;

