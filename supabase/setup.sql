-- 로또 번호 연구소: "모두의 히스토리" 공유 기능용 데이터베이스 설정
-- Supabase 대시보드 → SQL Editor → New query 에 전체를 붙여 넣고 Run 을 누르세요.
-- 처음 설정할 때는 이 파일을 실행한 뒤 update-2.sql, update-3.sql, update-4.sql 을 차례로 이어서 실행하세요.
-- 주의: 실행하면 공유 기능 데이터가 처음 상태로 돌아갑니다. (처음 설정할 때만 실행하세요)
--
-- 구조
--  - 사용자는 닉네임만 정합니다. 닉네임은 언제든 바꿀 수 있고 다른 사람과 같아도 됩니다.
--  - 누가 누구인지는 브라우저가 자동으로 만든 숨은 열쇠로 구분합니다. (열쇠의 해시만 저장)
--  - 번호는 그 회차 판매 마감(토 20:00) 전에만 저장·삭제할 수 있습니다.

create extension if not exists pgcrypto;

drop view if exists public.shared_picks;
drop function if exists public.save_pick(text,text,int,int,int[]);
drop function if exists public.delete_pick(text,text,int,int);
drop function if exists public.check_player(text,text);
drop function if exists public.set_nickname(text,text);
drop function if exists public.delete_pick(text,int,int);
drop table if exists public.picks cascade;
drop table if exists public.players cascade;

create table public.players (
  owner      text primary key,                 -- 브라우저 열쇠의 sha256 (원래 열쇠는 저장 안 함)
  nickname   text not null check (char_length(nickname) between 1 and 12),
  updated_at timestamptz not null default now()
);

create table public.picks (
  id         bigint generated always as identity primary key,
  owner      text not null references public.players(owner) on delete cascade,
  round      int  not null check (round > 0),
  slot       smallint not null check (slot between 0 and 4),
  numbers    smallint[] not null,
  created_at timestamptz not null default now(),
  unique (owner, round, slot)
);
create index picks_round_idx on public.picks(round);

-- 직접 읽기·쓰기는 모두 막고, 아래 보기(view)와 함수로만 씁니다.
alter table public.players enable row level security;
alter table public.picks   enable row level security;
revoke all on public.players from anon, authenticated;
revoke all on public.picks   from anon, authenticated;

-- 모두에게 보이는 목록: uid 는 열쇠 해시 앞 8자리(사람 구분용), 닉네임은 최신 닉네임
create view public.shared_picks as
  select left(p.owner, 8) as uid, pl.nickname, p.round, p.slot, p.numbers
  from public.picks p join public.players pl using (owner);
grant select on public.shared_picks to anon, authenticated;

-- 회차 N의 판매 마감 시각 (1회 2002-12-07 토 20:00 KST, 매주 1회)
create or replace function public.round_close_at(p_round int)
returns timestamptz language sql immutable as $$
  select timestamptz '2002-12-07 20:00:00+09' + (p_round - 1) * interval '7 days'
$$;

-- 지금 번호를 받을 수 있는 회차
create or replace function public.open_round()
returns int language sql stable as $$
  select floor(extract(epoch from (now() - timestamptz '2002-12-07 20:00:00+09')) / 604800)::int + 2
$$;

create or replace function public._owner(p_key text)
returns text language plpgsql immutable set search_path = public, extensions as $$
begin
  if p_key !~ '^[A-Za-z0-9_-]{16,64}$' then raise exception '브라우저 정보가 올바르지 않아요. 새로고침해 주세요'; end if;
  return encode(digest(p_key, 'sha256'), 'hex');
end $$;

-- 닉네임 정하기·바꾸기
create function public.set_nickname(p_key text, p_nickname text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  p_nickname := btrim(p_nickname);
  if char_length(p_nickname) not between 1 and 12 then raise exception '닉네임은 1~12자로 정해 주세요'; end if;
  insert into players(owner, nickname) values (public._owner(p_key), p_nickname)
  on conflict (owner) do update set nickname = excluded.nickname, updated_at = now();
end $$;

-- 번호 저장 (같은 자리에 다시 저장하면 바꿔 씁니다)
create function public.save_pick(p_key text, p_nickname text, p_round int, p_slot int, p_numbers int[])
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_owner text := public._owner(p_key); v_nums smallint[];
begin
  if p_round <> public.open_round() then raise exception '지금은 %회 번호만 저장할 수 있어요', public.open_round(); end if;
  if now() >= public.round_close_at(p_round) then raise exception '%회 판매가 마감됐어요', p_round; end if;
  if p_slot not between 0 and 4 then raise exception '자리는 A~E만 쓸 수 있어요'; end if;
  select array_agg(x order by x)::smallint[] into v_nums from (select distinct unnest(p_numbers) x) s;
  if coalesce(array_length(v_nums,1),0) <> 6 or exists (select 1 from unnest(v_nums) x where x not between 1 and 45) then
    raise exception '번호는 1~45 사이 서로 다른 6개여야 해요';
  end if;
  perform public.set_nickname(p_key, p_nickname);
  insert into picks(owner, round, slot, numbers) values (v_owner, p_round, p_slot, v_nums)
  on conflict (owner, round, slot) do update set numbers = excluded.numbers, created_at = now();
end $$;

-- 번호 삭제 (내 브라우저 것, 마감 전 회차만)
create function public.delete_pick(p_key text, p_round int, p_slot int)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if now() >= public.round_close_at(p_round) then raise exception '추첨이 끝난 번호는 지울 수 없어요'; end if;
  delete from picks where owner = public._owner(p_key) and round = p_round and slot = p_slot;
end $$;

revoke all on function public.set_nickname(text,text), public.save_pick(text,text,int,int,int[]), public.delete_pick(text,int,int), public._owner(text) from public;
grant execute on function public.set_nickname(text,text), public.save_pick(text,text,int,int,int[]), public.delete_pick(text,int,int), public.open_round(), public.round_close_at(int) to anon, authenticated;
