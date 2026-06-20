# moTF Supabase 데이터베이스 기록

이 저장소는 이용자 사이트와 사장님·운영팀 사이트가 함께 사용하는 Supabase SQL 실행 기록입니다.

## 중요한 원칙

- 파일 번호는 Supabase에서 실제로 실행한 순서입니다.
- 현재 프로젝트에는 01~08이 이미 적용되어 있으므로 새 프로젝트가 아닌 이상 다시 실행하지 않습니다.
- 02와 05는 특정 계정을 관리자로 지정한 일회성 작업입니다.
- 03과 06은 기존 가입자의 누락 데이터를 복구한 일회성 작업입니다.
- 앞으로 변경할 때 기존 파일을 수정하지 말고 09부터 새 SQL 파일을 추가합니다.
- 비밀번호, service_role 키, secret 키는 이 저장소에 절대 기록하지 않습니다.

## 현재 파일

1. `01_initial_auth_and_business.sql` — 회원, 업장, 가입 트리거, 기본 RLS
2. `02_promote_first_admin.sql` — 최초 운영자 지정 기록
3. `03_backfill_profiles_and_permissions.sql` — 누락 프로필 복구 및 기본 권한
4. `04_partner_review_function.sql` — 파트너 가입 승인·거절 함수
5. `05_promote_replacement_admin.sql` — 변경된 운영자 지정 기록
6. `06_backfill_businesses.sql` — 누락 업장 정보 복구
7. `07_platform_schema.sql` — 상품, 예약, 채팅
8. `08_admin_content_schema.sql` — 문의, 분쟁, 리뷰, 커뮤니티
9. `09_customer_signup_roles.sql` — 이용자와 파트너 신규 가입 역할 분리
10. `10_customer_profile_organization.sql` — 이용자 학교·소속 정보 및 수정 권한 추가
11. `11_admin_account_status_management.sql` — 운영진 회원·파트너 상태 관리 함수
12. `12_partner_signup_business_creation.sql` — 파트너 가입 시 승인 대기 업장 자동 생성
13. `13_public_catalog_and_offerings.sql` — 실제 업장·객실·상품 공개 카탈로그 연결
14. `14_catalog_image_storage.sql` — 업장·객실·상품 사진 저장소 및 접근 정책
15. `15_reservations_and_market_orders.sql` — 실제 숙소 예약·공판장 주문 및 상태 처리

## 다음 개발 시 주의

09번 적용 후 일반 이용자와 카카오 신규 가입자는 `user / approved`, 사업자 정보가 포함된 파트너 가입자는 `partner / pending`으로 생성됩니다. 브라우저가 `admin` 역할을 요청하더라도 관리자로 생성되지 않습니다.
