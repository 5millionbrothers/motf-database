# moTF 현재 상태 메모

작성일: 2026-06-23

## 운영 도메인

```text
이용자: https://motf.co.kr
사장님/관리자: https://motfowner.co.kr
```

`www` 서브도메인은 각 Vercel 프로젝트에 함께 연결해 둔다.

## 완료된 기반 작업

- 이용자와 사장님/관리자 앱을 별도 Vercel 프로젝트와 도메인으로 운영한다.
- 사장님 앱에서 카카오/다음 우편번호 API로 도로명주소와 우편번호를 선택한다.
- 사장님 앱에서 네이버 Geocoding으로 주소를 `latitude`, `longitude` 좌표로 저장한다.
- 이용자 앱 지도는 저장된 좌표가 있는 승인 업장을 네이버 지도 마커로 표시한다.
- 예약과 공판장 주문은 결제 전 `payment_intents`를 만들고, 토스 승인 후 예약·주문을 생성하는 구조다.
- 사장님과 관리자는 실제 `reservations`, `market_orders` 데이터를 조회하고 확정/거절 RPC로 상태를 바꾼다.
- 거절된 선결제 요청은 결제 완료 기록이 있을 때만 `refund_status = required`로 표시되어 나중에 토스 자동환불 API가 처리할 수 있다.

## Supabase SQL 기준

운영 DB 기준 마이그레이션은 `01`부터 `25`까지다.

- `21_toss_payment_intents.sql`: 토스 결제 대기 원장과 승인 후 거래 생성
- `22_business_coordinates.sql`: 업장 지도 좌표 저장
- `23_business_postcode_address.sql`: 우편번호와 상세주소 저장
- `24_refund_status_foundation.sql`: 거절 시 환불 필요 상태 저장
- `25_refund_requires_confirmed_payment.sql`: 결제 완료 기록이 있는 요청만 환불 필요 상태로 보정

새 SQL은 기존 파일 수정 없이 다음 번호로 추가한다.

## Vercel 환경변수

이용자 앱:

```text
TOSS_CLIENT_KEY
TOSS_SECRET_KEY
NAVER_MAP_KEY_ID
SUPABASE_URL
SUPABASE_PUBLISHABLE_KEY
SUPABASE_SERVICE_ROLE_KEY
```

사장님/관리자 앱:

```text
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
NAVER_MAP_KEY_ID
```

`TOSS_SECRET_KEY`와 `SUPABASE_SERVICE_ROLE_KEY`는 이용자 앱의 서버 API에서만 사용한다.

## 외부 콘솔 등록 기준

Supabase Authentication Redirect URLs:

```text
https://motf.co.kr/**
https://www.motf.co.kr/**
https://motfowner.co.kr/**
https://www.motfowner.co.kr/**
```

네이버 클라우드 Maps:

- `Web Dynamic Map` 활성화
- `Geocoding` 활성화
- 이용자/사장님 운영 도메인과 테스트용 Vercel 도메인 등록

## 다음 권장 순서

1. 운영 도메인 기준으로 회원가입, 이메일 인증, 로그인, 로그아웃을 다시 확인한다.
2. 실제 승인 숙소 1개와 공판장 1개로 예약·주문 결제 전 단계까지 확인한다.
3. 토스 테스트 키를 넣고 숙소 결제 성공, 새로고침 중복 방지, 마이페이지 표시를 확인한다.
4. 사장님 거절 시 결제 완료 건만 `refund_status = required`가 남는지 확인하고 토스 결제 취소 API를 연결한다.
5. 공판장 결제도 같은 방식으로 확인한다.
6. 결제 취소·환불 정책과 운영자 처리 화면을 설계한 뒤 토스 운영 키 전환을 검토한다.
7. 카카오 로그인은 이용자 인증 흐름이 안정된 뒤 붙인다.
8. 카카오 챗봇은 FAQ, 예약 상태 조회, 문의 연결 순서로 붙인다.
