-- 이용자 마이페이지 회원정보 저장 연결
-- profiles에 학교·소속 정보를 추가하고 본인 정보 수정 권한을 허용합니다.

alter table public.profiles
add column if not exists organization text;

grant update (organization, phone, updated_at)
on public.profiles
to authenticated;
