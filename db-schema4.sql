-- ============================================================
--  사교원 사회혁신팀러닝 — 4차 스키마 (관리자 추가 체계)
--  실행: Supabase > SQL Editor > 전체 붙여넣기 > Run
--  구조: 최고관리자(is_admin=사교원 계정)는 그대로,
--        tl_admins 명부에 "신청→승인"으로 일반 관리자를 추가
--  전체 idempotent — 여러 번 실행해도 안전
-- ============================================================

-- ------------------------------------------------------------
-- 1) tl_admins : 팀러닝 관리자 명부 (신청 → 최고관리자 승인)
-- ------------------------------------------------------------
create table if not exists public.tl_admins (
  email      text primary key,
  name       text not null default '',
  approved   boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.tl_admins enable row level security;

-- 신청: 로그인한 본인이 자기 이메일로만 등록 가능
drop policy if exists tl_admins_signup on public.tl_admins;
create policy tl_admins_signup on public.tl_admins
  for insert with check ( email = (auth.jwt() ->> 'email') );

-- 본인 행 조회 (승인 대기 상태 확인용)
drop policy if exists tl_admins_self on public.tl_admins;
create policy tl_admins_self on public.tl_admins
  for select using ( email = (auth.jwt() ->> 'email') );

-- 최고관리자: 전체 조회·승인·삭제
drop policy if exists tl_admins_super on public.tl_admins;
create policy tl_admins_super on public.tl_admins
  for all using ( is_admin() ) with check ( is_admin() );

-- ------------------------------------------------------------
-- 2) tl_is_admin() : "최고관리자 또는 승인된 팀러닝 관리자"
-- ------------------------------------------------------------
create or replace function public.tl_is_admin()
returns boolean language sql security definer set search_path = public stable as $$
  select public.is_admin() or exists (
    select 1 from tl_admins
    where email = (auth.jwt() ->> 'email') and approved = true
  );
$$;

-- ------------------------------------------------------------
-- 3) 기존 tl_ 테이블 정책을 tl_is_admin() 기준으로 교체
--    (팀 접근은 여전히 토큰 RPC — 변화 없음)
-- ------------------------------------------------------------
drop policy if exists tl_teams_admin     on public.tl_teams;
drop policy if exists tl_questions_admin on public.tl_questions;
drop policy if exists tl_plans_admin     on public.tl_plans;
drop policy if exists tl_research_admin  on public.tl_research;
drop policy if exists tl_reports_admin   on public.tl_reports;
drop policy if exists tl_notifications_admin on public.tl_notifications;

create policy tl_teams_admin on public.tl_teams
  for all using ( tl_is_admin() ) with check ( tl_is_admin() );
create policy tl_questions_admin on public.tl_questions
  for all using ( tl_is_admin() ) with check ( tl_is_admin() );
create policy tl_plans_admin on public.tl_plans
  for all using ( tl_is_admin() ) with check ( tl_is_admin() );
create policy tl_research_admin on public.tl_research
  for all using ( tl_is_admin() ) with check ( tl_is_admin() );
create policy tl_reports_admin on public.tl_reports
  for all using ( tl_is_admin() ) with check ( tl_is_admin() );
create policy tl_notifications_admin on public.tl_notifications
  for all using ( tl_is_admin() ) with check ( tl_is_admin() );

-- 끝. Run 후 "Success" 나오면 완료.
-- 참고: 최고관리자(사교원 계정)는 tl_is_admin()에 포함되므로 기존과 동일하게 작동.
