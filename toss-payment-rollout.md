# Toss Payments 출시 적용 순서

기준일: 2026-08-29

## 현재 결제 구조

1. 브라우저가 예약 또는 장보기 내용을 Supabase RPC에 전달한다.
2. DB가 실제 객실·상품 가격으로 `payment_intents`를 만들고 재고를 15분간 선점한다.
3. 포인트와 할인코드는 moTF 부담 할인으로 적용하며 사장님 정산은 할인 전 판매가를 기준으로 한다.
4. Toss 결제창은 DB가 반환한 주문번호와 최종 외부 결제금액만 사용한다.
5. 성공 URL의 `paymentKey`, `orderId`, `amount`를 Vercel API가 다시 검증하고 Toss 승인 API를 호출한다.
6. `finalize_toss_payment_intent`가 예약 또는 주문을 한 번만 생성한다.
7. 사장님·운영팀 거절은 Toss 전액 취소 성공 후 DB 상태, 포인트, 방막기, 정산을 함께 갱신한다.

숙소 예약 결제에는 객실 기본금만 포함합니다. 추가 인원과 부대시설 금액은 현장에서 사장님에게 직접 결제합니다.

## 이용자 Vercel 환경변수

```text
SUPABASE_URL
SUPABASE_PUBLISHABLE_KEY
SUPABASE_SERVICE_ROLE_KEY
TOSS_CLIENT_KEY
TOSS_SECRET_KEY
TOSS_ENABLED_METHODS=CARD,TRANSFER
```

가상계좌 계약이 열린 뒤에만 `TOSS_ENABLED_METHODS=CARD,TRANSFER,VIRTUAL_ACCOUNT`로 변경합니다.

## 사장님 Vercel 환경변수

```text
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
SUPABASE_SERVICE_ROLE_KEY
TOSS_SECRET_KEY
```

`TOSS_SECRET_KEY`와 `SUPABASE_SERVICE_ROLE_KEY`는 서버 환경변수이며 브라우저 코드나 `NEXT_PUBLIC_*` 이름으로 노출하면 안 됩니다.

## Toss 콘솔

- 성공·실패 URL의 운영 도메인 등록 상태를 확인한다.
- 웹훅 URL은 `https://motf.co.kr/api/toss-webhook`으로 등록한다.
- 테스트 키와 운영 키를 섞지 않는다.
- 카드·계좌이체를 먼저 열고 가상계좌는 계약 승인 이후 활성화한다.

## 필수 테스트

- 카드 결제 성공, 사용자 취소, 승인 실패
- 계좌이체 성공과 중복 성공 URL 새로고침
- 같은 웹훅 재전송 시 거래 중복 생성 방지
- 결제 중 15분 만료 시 객실·상품 선점 해제
- 사장님 거절 시 전액 취소와 포인트 복구
- 이용자 취소 시 14일 100%, 7일 50%, 3일 20%, 이후 0% 규칙
- 부분환불 후 남은 취소수수료 기준 사장님 정산 생성
- 포인트·쿠폰을 사용해도 정산은 할인 전 판매가 기준인지 확인

## 과거 데이터

PortOne 관련 기존 마이그레이션과 컬럼은 과거 거래 조회를 위해 보존합니다. 신규 결제 API와 브라우저 SDK에서는 사용하지 않습니다.
