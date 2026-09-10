# moTF 알림톡 발송 구조

작성일: 2026-07-05

## 목적

알림톡 발송 대기열, 이벤트 트리거, 즉시 발송과 재시도를 관리하는 구조입니다.

`api/notifications-dispatch.js`는 `ALIGO_LIVE_ENABLED` 설정에 따라 알리고 실발송 또는 `mock_sent` 테스트 발송을 사용합니다. Supabase 즉시 호출이 실패하더라도 Vercel의 5분 크론이 대기열을 다시 처리합니다.

## 구성

### Supabase

SQL 파일:

```text
motf-database/supabase/40_notification_foundation.sql
```

생성되는 주요 테이블:

| 테이블 | 의미 |
| --- | --- |
| `notification_templates` | 알림톡 내부 템플릿 목록 |
| `notification_outbox` | 앞으로 발송해야 할 알림 대기열 |
| `notification_logs` | 발송 성공/실패 기록 |

주요 RPC:

| 함수 | 의미 |
| --- | --- |
| `enqueue_notification` | 알림 발송 대기열에 새 알림 추가 |
| `claim_notification_batch` | 발송 대기 알림을 처리 중 상태로 가져오기 |
| `complete_notification` | 발송 결과를 성공/실패로 기록 |

### Vercel API

```text
motf-prototype/api/notifications-dispatch.js
```

역할:

1. `notification_outbox`에서 `queued` 상태 알림을 가져옵니다.
2. 운영 설정에서는 알리고 API로, 테스트 설정에서는 mock으로 발송합니다.
3. 성공 시 `sent` 또는 `mock_sent` 상태로 변경하고 `notification_logs`에 기록합니다.
4. 실패 시 재시도 가능하도록 다시 `queued` 또는 최종 `failed`로 기록합니다.

## 보안

발송 API는 아래 둘 중 하나로만 실행됩니다.

1. 관리자 계정 로그인 토큰
2. Vercel 환경변수 `NOTIFICATION_DISPATCH_SECRET`과 요청 헤더 `x-notification-secret`

크론이나 서버 작업으로 자동 실행하려면 나중에 `NOTIFICATION_DISPATCH_SECRET`을 Vercel에 추가하고, 같은 값을 헤더로 보내면 됩니다.

## 수동 테스트 흐름

1. Supabase SQL Editor에서 `40_notification_foundation.sql` 실행
2. Supabase SQL Editor에서 테스트 알림 추가

```sql
select public.enqueue_notification(
  'manual_test',
  'USER_CHAT_RECEIVED_V1',
  'user',
  null,
  '테스트 이용자',
  '010-0000-0000',
  '{"고객명":"테스트 이용자","상대명":"모티프","관련건":"테스트"}'::jsonb,
  '{"채팅 확인":"https://motf.co.kr/chat"}'::jsonb,
  'manual_test_001',
  now()
);
```

3. 관리자 로그인 상태에서 아래 API 호출

```text
POST https://motf.co.kr/api/notifications-dispatch
Body: {"limit":20}
```

4. `notification_outbox`의 상태가 `mock_sent`로 바뀌고, `notification_logs`에 기록이 생기면 성공입니다.

## 다음 단계

## 자동 큐 적재 이벤트

SQL 파일:

```text
motf-database/supabase/41_notification_event_hooks.sql
```

아래 이벤트가 발생하면 `notification_outbox`에 자동으로 알림이 쌓입니다.

| 이벤트 | 쌓이는 알림 |
| --- | --- |
| 가상계좌 발급 | 이용자 가상계좌 발급 안내 |
| 예약 요청 생성 | 이용자 예약 요청 접수, 사장님 새 예약 요청 |
| 예약 확정 | 이용자 예약 확정, 관리자 예약 상태 변경 |
| 예약 취소/거절 | 이용자 예약 취소/환불 안내, 관리자 예약 상태 변경, 환불 필요 알림 |
| 공판장 주문 생성 | 이용자 주문 접수, 사장님 새 주문 요청, 관리자 새 주문 |
| 공판장 주문 상태 변경 | 이용자 주문 상태 변경, 환불 필요 시 관리자 알림 |
| 채팅 메시지 생성 | 미접속 수신자에게 첫 미확인 문의/답변 즉시 알림 |

채팅 알림은 같은 대화방을 보고 있는 수신자에게는 발송하지 않습니다. 수신자가 미접속 상태일 때 첫 미확인 메시지만 즉시 발송하고, 읽기 전 추가 메시지는 발송하지 않습니다. 수신자가 대화를 읽으면 상태가 초기화되어 이후 새 메시지 묶음에서 다시 1회 발송됩니다.

이 정책은 `supabase/46_chat_notification_presence.sql` 적용 후 활성화됩니다. 알리고에서 수정 템플릿이 승인되면 두 채팅 템플릿의 DB 상태를 `approved`로 변경하고 실제 발송 테스트를 진행합니다.

## 다음 단계

1. 결제수단 중립 문구의 V2 템플릿 승인 및 코드 매핑
2. 토스 가상계좌 활성화 전 `WAITING_FOR_DEPOSIT`/`DEPOSIT_CALLBACK` 보완
3. 체크인·픽업·리뷰 요청 스케줄 알림 추가

상세 점검 결과는 `docs/payment-notification-audit-20260911.md`를 참고합니다.
