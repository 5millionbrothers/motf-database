# moTF 알림톡 발송 구조

작성일: 2026-07-05

## 목적

카카오 알림톡 딜러사를 선택하기 전에도 알림 시스템 개발을 진행하기 위한 기초 구조입니다.

현재 단계에서는 실제 카카오톡 메시지를 보내지 않고 `mock_sent` 상태로 처리합니다.  
나중에 SOLAPI, NHN Cloud, 비즈톡 등 딜러사를 선택하면 `api/notifications-dispatch.js`의 mock 발송 부분을 실제 API 호출로 교체합니다.

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
2. 현재는 실제 발송 대신 mock 발송 처리합니다.
3. 성공 시 `mock_sent` 상태로 변경하고 `notification_logs`에 기록합니다.
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
| 채팅 메시지 생성 | 상대방에게 채팅 도착 알림 |

채팅 알림은 같은 대화방/수신자 기준 약 5분 단위로 dedupe key가 묶여 과도하게 쌓이지 않도록 설계되어 있습니다.

## 다음 단계

1. 딜러사 선택
2. 승인된 템플릿 코드 입력
3. 실제 발송 API 연결
4. 사장님 수락/취소용 일회용 토큰 페이지 구현
5. 입금 기한 임박 알림용 스케줄러 추가
