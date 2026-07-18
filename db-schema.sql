-- ============================================================
--  사교원 사회혁신팀러닝 — DB 스키마 (tl_ 접두사)
--  실행: Supabase > SQL Editor > 전체 붙여넣기 > Run
--  구조: 팀은 로그인 없이 "전용 링크(토큰)"로만 접근 (RPC 경유)
--        관리자(is_admin)는 테이블 직접 접근
--  전체 idempotent — 여러 번 실행해도 안전
-- ============================================================

-- ------------------------------------------------------------
-- 1) 테이블
-- ------------------------------------------------------------

-- 팀 (등록 시 토큰 발급 → 전용 링크)
create table if not exists public.tl_teams (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  topic      text not null default '',
  token      text not null unique default replace(gen_random_uuid()::text, '-', ''),
  created_at timestamptz not null default now()
);

-- 질문 (팀 → 접수, 관리자 → AI답변+추가조언 게시)
create table if not exists public.tl_questions (
  id          bigint generated always as identity primary key,
  team_id     uuid not null references public.tl_teams(id) on delete cascade,
  content     text not null,
  ai_answer   text,               -- AI(데카) 답변 초안
  advice      text,               -- 이사장 추가 조언
  status      text not null default '대기중',   -- 대기중 / 답변완료
  created_at  timestamptz not null default now(),
  answered_at timestamptz
);

-- 계획안 (팀 → 제출, 관리자 → 보완 계획서 게시)
create table if not exists public.tl_plans (
  id          bigint generated always as identity primary key,
  team_id     uuid not null references public.tl_teams(id) on delete cascade,
  title       text not null default '',
  content     text not null,
  review      text,               -- 보완 계획서
  status      text not null default '대기중',   -- 대기중 / 보완완료
  created_at  timestamptz not null default now(),
  reviewed_at timestamptz
);

-- 자료조사 (팀 → 주제 요청, 관리자 → 조사자료 게시)
create table if not exists public.tl_research (
  id           bigint generated always as identity primary key,
  team_id      uuid not null references public.tl_teams(id) on delete cascade,
  topic        text not null,
  note         text not null default '',   -- 요청 배경/원하는 방향
  materials    text,                       -- 조사자료 본문
  status       text not null default '대기중',   -- 대기중 / 게시완료
  created_at   timestamptz not null default now(),
  published_at timestamptz
);

-- 최종 보고 (팀러닝 종료 시 종합요약, 팀당 1건)
create table if not exists public.tl_reports (
  team_id      uuid primary key references public.tl_teams(id) on delete cascade,
  title        text not null default '',
  content      text not null,
  published_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 2) RLS — 익명 직접 접근 전면 차단, 관리자만 직접 접근
-- ------------------------------------------------------------
alter table public.tl_teams     enable row level security;
alter table public.tl_questions enable row level security;
alter table public.tl_plans     enable row level security;
alter table public.tl_research  enable row level security;
alter table public.tl_reports   enable row level security;

drop policy if exists tl_teams_admin     on public.tl_teams;
drop policy if exists tl_questions_admin on public.tl_questions;
drop policy if exists tl_plans_admin     on public.tl_plans;
drop policy if exists tl_research_admin  on public.tl_research;
drop policy if exists tl_reports_admin   on public.tl_reports;

create policy tl_teams_admin on public.tl_teams
  for all using ( is_admin() ) with check ( is_admin() );
create policy tl_questions_admin on public.tl_questions
  for all using ( is_admin() ) with check ( is_admin() );
create policy tl_plans_admin on public.tl_plans
  for all using ( is_admin() ) with check ( is_admin() );
create policy tl_research_admin on public.tl_research
  for all using ( is_admin() ) with check ( is_admin() );
create policy tl_reports_admin on public.tl_reports
  for all using ( is_admin() ) with check ( is_admin() );

-- ------------------------------------------------------------
-- 3) RPC 함수 — 팀(익명)은 전부 이 함수로만 접근
--    security definer: RLS를 우회하되 토큰이 맞는 행만 다룸
-- ------------------------------------------------------------

-- 팀 등록 → 토큰 반환
create or replace function public.tl_register_team(p_name text, p_topic text)
returns text language plpgsql security definer set search_path = public as $$
declare v_token text;
begin
  if coalesce(trim(p_name),'') = '' then
    raise exception '팀명을 입력해 주세요';
  end if;
  if length(p_name) > 60 or length(coalesce(p_topic,'')) > 200 then
    raise exception '입력이 너무 깁니다';
  end if;
  insert into tl_teams(name, topic)
  values (trim(p_name), coalesce(trim(p_topic),''))
  returning token into v_token;
  return v_token;
end $$;

-- 토큰 → 팀 정보
create or replace function public.tl_get_team(p_token text)
returns table(name text, topic text, created_at timestamptz)
language sql security definer set search_path = public stable as $$
  select t.name, t.topic, t.created_at
  from tl_teams t where t.token = p_token;
$$;

-- 질문 접수
create or replace function public.tl_submit_question(p_token text, p_content text)
returns void language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  select id into v_id from tl_teams where token = p_token;
  if v_id is null then raise exception '유효하지 않은 팀 링크입니다'; end if;
  if coalesce(trim(p_content),'') = '' then raise exception '내용을 입력해 주세요'; end if;
  if length(p_content) > 5000 then raise exception '내용이 너무 깁니다'; end if;
  insert into tl_questions(team_id, content) values (v_id, trim(p_content));
end $$;

-- 질문 목록
create or replace function public.tl_list_questions(p_token text)
returns table(id bigint, content text, ai_answer text, advice text,
              status text, created_at timestamptz, answered_at timestamptz)
language sql security definer set search_path = public stable as $$
  select q.id, q.content, q.ai_answer, q.advice, q.status, q.created_at, q.answered_at
  from tl_questions q join tl_teams t on t.id = q.team_id
  where t.token = p_token order by q.created_at desc;
$$;

-- 계획안 제출
create or replace function public.tl_submit_plan(p_token text, p_title text, p_content text)
returns void language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  select id into v_id from tl_teams where token = p_token;
  if v_id is null then raise exception '유효하지 않은 팀 링크입니다'; end if;
  if coalesce(trim(p_content),'') = '' then raise exception '내용을 입력해 주세요'; end if;
  if length(p_content) > 50000 then raise exception '내용이 너무 깁니다'; end if;
  insert into tl_plans(team_id, title, content)
  values (v_id, coalesce(trim(p_title),''), trim(p_content));
end $$;

-- 계획안 목록
create or replace function public.tl_list_plans(p_token text)
returns table(id bigint, title text, content text, review text,
              status text, created_at timestamptz, reviewed_at timestamptz)
language sql security definer set search_path = public stable as $$
  select p.id, p.title, p.content, p.review, p.status, p.created_at, p.reviewed_at
  from tl_plans p join tl_teams t on t.id = p.team_id
  where t.token = p_token order by p.created_at desc;
$$;

-- 자료조사 요청
create or replace function public.tl_submit_research(p_token text, p_topic text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  select id into v_id from tl_teams where token = p_token;
  if v_id is null then raise exception '유효하지 않은 팀 링크입니다'; end if;
  if coalesce(trim(p_topic),'') = '' then raise exception '조사 주제를 입력해 주세요'; end if;
  if length(p_topic) > 200 or length(coalesce(p_note,'')) > 3000 then
    raise exception '입력이 너무 깁니다';
  end if;
  insert into tl_research(team_id, topic, note)
  values (v_id, trim(p_topic), coalesce(trim(p_note),''));
end $$;

-- 자료조사 목록
create or replace function public.tl_list_research(p_token text)
returns table(id bigint, topic text, note text, materials text,
              status text, created_at timestamptz, published_at timestamptz)
language sql security definer set search_path = public stable as $$
  select r.id, r.topic, r.note, r.materials, r.status, r.created_at, r.published_at
  from tl_research r join tl_teams t on t.id = r.team_id
  where t.token = p_token order by r.created_at desc;
$$;

-- 최종 보고 조회
create or replace function public.tl_get_report(p_token text)
returns table(team_name text, topic text, title text, content text, published_at timestamptz)
language sql security definer set search_path = public stable as $$
  select t.name, t.topic, r.title, r.content, r.published_at
  from tl_reports r join tl_teams t on t.id = r.team_id
  where t.token = p_token;
$$;

-- 끝. Run 후 "Success" 나오면 완료.
