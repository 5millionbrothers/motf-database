# 토스페이먼츠 적용 순서

## 구조

1. 이용자가 예약·주문 정보를 입력한다.
2. Supabase가 실제 상품 가격으로 `payment_intents` 결제 대기표를 만든다.
3. 브라우저는 DB가 반환한 주문번호와 금액으로 토스 결제창을 연다.
4. Vercel API가 로그인 사용자, 주문번호, 금액을 다시 확인하고 토스 승인을 요청한다.
5. 승인 성공 후 `finalize_payment_intent`가 예약 또는 주문을 한 번만 생성한다.

## 적용

1. Supabase SQL Editor에서 `21_toss_payment_intents.sql`을 한 번 실행한다.
2. Vercel 이용자 웹 프로젝트에 README의 결제 환경변수 다섯 개를 추가한다.
3. 테스트 키로 숙소 예약 결제를 실행한다.
4. `payment_intents.status`가 `confirmed`이고 `reservations`에 한 건만 생성됐는지 확인한다.
5. 같은 성공 URL을 새로고침해도 예약이 추가 생성되지 않는지 확인한다.
6. 공판장도 같은 방식으로 `market_orders`, `market_order_items`를 확인한다.

## 운영 전 필수

- 테스트 결제 취소 API와 환불 정책 연결
- 토스 웹훅 서명 검증 및 결제 상태 동기화
- 운영 키 전환 전 전체 취소·실패·재시도 시나리오 검사
