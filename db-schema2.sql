-- ============================================================
--  사교원 사회혁신팀러닝 — 2차 스키마 (전화번호 회신 + 알림함)
--  실행: Supabase > SQL Editor > 전체 붙여넣기 > Run
--  내용: ① 질문에 전화번호(선택) ② 답변 게시 시 문자 발송대기 자동 적재
--  전체 idempotent — 여러 번 실행해도 안전
-- ============================================================

-- ------------------------------------------------------------
-- 1) tl_questions에 전화번호 컬럼 (선택 입력, 관리자만 열람)
-- ------------------------------------------------------------
alter table public.tl_questions add column if not exists phone text;

-- ------------------------------------------------------------
-- 2) 질문 접수 RPC 개정 — 전화번호(선택) 받도록
--    (기존 2인자 버전은 삭제해야 함수 중복이 안 생김)
-- ------------------------------------------------------------
drop function if exists public.tl_submit_question(text, text);

create or replace function public.tl_submit_question(p_token text, p_content text, p_phone text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  select id into v_id from tl_teams where token = p_token;
  if v_id is null then raise exception '유효하지 않은 팀 링크입니다'; end if;
  if coalesce(trim(p_content),'') = '' then raise exception '내용을 입력해 주세요'; end if;
  if length(p_content) > 5000 then raise exception '내용이 너무 깁니다'; end if;
  if length(coalesce(p_phone,'')) > 20 then raise exception '전화번호가 너무 깁니다'; end if;
  insert into tl_questions(team_id, content, phone)
  values (v_id, trim(p_content), nullif(trim(coalesce(p_phone,'')), ''));
end $$;

-- ------------------------------------------------------------
-- 3) tl_notifications : 문자 발송 대기함
--    답변 게시 시 트리거가 자동으로 쌓음. 관리자만 접근.
--    문자 게이트웨이 연결 전에는 관리페이지에서 복사→수동 발송.
-- ------------------------------------------------------------
create table if not exists public.tl_notifications (
  id          bigint generated always as identity primary key,
  question_id bigint references public.tl_questions(id) on delete cascade,
  phone       text not null,
  message     text not null,
  status      text not null default '발송대기',   -- 발송대기 / 발송완료
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);

alter table public.tl_notifications enable row level security;
drop policy if exists tl_notifications_admin on public.tl_notifications;
create policy tl_notifications_admin on public.tl_notifications
  for all using ( is_admin() ) with check ( is_admin() );

-- ------------------------------------------------------------
-- 4) 트리거 — 질문이 '답변완료'로 바뀌는 순간, 전화번호가 있으면
--    발송 대기 메시지를 자동 생성
-- ------------------------------------------------------------
create or replace function public.tl_queue_answer_sms()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_token text; v_team text;
begin
  if new.status = '답변완료' and old.status is distinct from '답변완료'
     and coalesce(new.phone,'') <> '' then
    select token, name into v_token, v_team from tl_teams where id = new.team_id;
    insert into tl_notifications(question_id, phone, message)
    values (new.id, new.phone,
      '[사교원 팀러닝] ' || coalesce(v_team,'') || ' 질문에 답변이 게시되었습니다. 팀 공간에서 확인해 주세요: '
      || 'https://deka2026.github.io/teamlearning-site/team.html?t=' || v_token);
  end if;
  return new;
end $$;

drop trigger if exists tl_questions_sms on public.tl_questions;
create trigger tl_questions_sms after update on public.tl_questions
  for each row execute function public.tl_queue_answer_sms();

-- 끝. Run 후 "Success" 나오면 완료.
