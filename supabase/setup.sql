-- 로또 번호 연구소: "모두의 번호" 공유 기능용 데이터베이스 설정
-- Supabase 대시보드 → SQL Editor → New query 에 전체를 붙여 넣고 Run 을 누르세요.
-- 여러 번 실행해도 안전합니다.

create extension if not exists pgcrypto;

-- 닉네임과 브라우저 열쇠. 사용자는 닉네임만 정하고, 열쇠는 브라우저가 자동으로 만들어 보관합니다.
-- 열쇠는 해시로만 저장하고 밖에서는 읽을 수 없습니다. (열 이름 pin_hash 는 그대로 둡니다)
create table if not exists public.players (
  nickname   text primary key check (char_length(nickname) between 2 and 12),
  pin_hash   text not null,
  created_at timestamptz not null default now()
);

-- 회차별로 공유한 번호 (닉네임당 한 회차 최대 5게임: 자리 A~E)
create table if not exists public.picks (
  id         bigint generated always as identity primary key,
  nickname   text not null references public.players(nickname) on delete cascade,
  round      int  not null check (round > 0),
  slot       smallint not null check (slot between 0 and 4),
  numbers    smallint[] not null,
  created_at timestamptz not null default now(),
  unique (nickname, round, slot)
);
create index if not exists picks_round_idx on public.picks(round);

-- 회차 N의 판매 마감 시각 (1회 2002-12-07 토 20:00 KST, 매주 1회)
create or replace function public.round_close_at(p_round int)
returns timestamptz language sql immutable as $$
  select timestamptz '2002-12-07 20:00:00+09' + (p_round - 1) * interval '7 days'
$$;

-- 지금 번호를 받을 수 있는 회차 (마감 전인 가장 가까운 회차)
create or replace function public.open_round()
returns int language sql stable as $$
  select floor(extract(epoch from (now() - timestamptz '2002-12-07 20:00:00+09')) / 604800)::int + 2
$$;

-- 행 단위 보안: 직접 쓰기는 모두 막고, 아래 함수로만 저장·삭제합니다.
alter table public.players enable row level security;
alter table public.picks   enable row level security;
drop policy if exists "picks 누구나 보기" on public.picks;
create policy "picks 누구나 보기" on public.picks for select using (true);
revoke all on public.players from anon, authenticated;
revoke all on public.picks   from anon, authenticated;
grant select (id, nickname, round, slot, numbers, created_at) on public.picks to anon, authenticated;

-- 이전 버전 함수 정리 (매개변수 이름이 바뀌어 다시 만들어야 합니다)
drop function if exists public.save_pick(text,text,int,int,int[]);
drop function if exists public.delete_pick(text,text,int,int);
drop function if exists public.check_player(text,text);

-- 번호 저장 (같은 자리에 다시 저장하면 바꿔 씁니다)
-- 처음 쓰는 닉네임이면 이 브라우저의 열쇠로 등록하고, 이미 있으면 같은 열쇠여야 합니다.
create or replace function public.save_pick(p_nickname text, p_key text, p_round int, p_slot int, p_numbers int[])
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text; v_nums smallint[];
begin
  p_nickname := btrim(p_nickname);
  if char_length(p_nickname) not between 2 and 12 then raise exception '닉네임은 2~12자로 정해 주세요'; end if;
  if p_key !~ '^[A-Za-z0-9_-]{16,64}$' then raise exception '브라우저 열쇠가 올바르지 않아요. 새로고침해 주세요'; end if;
  if p_round <> public.open_round() then raise exception '지금은 %회 번호만 저장할 수 있어요', public.open_round(); end if;
  if now() >= public.round_close_at(p_round) then raise exception '%회 판매가 마감됐어요', p_round; end if;
  if p_slot not between 0 and 4 then raise exception '자리는 A~E만 쓸 수 있어요'; end if;
  select array_agg(x order by x)::smallint[] into v_nums from (select distinct unnest(p_numbers) x) s;
  if coalesce(array_length(v_nums,1),0) <> 6 or exists (select 1 from unnest(v_nums) x where x not between 1 and 45) then
    raise exception '번호는 1~45 사이 서로 다른 6개여야 해요';
  end if;

  select pin_hash into v_hash from players where nickname = p_nickname;
  if v_hash is null then
    insert into players(nickname, pin_hash) values (p_nickname, crypt(p_key, gen_salt('bf')));
  elsif crypt(p_key, v_hash) <> v_hash then
    raise exception '이미 다른 사람이 쓰는 닉네임이에요. 다른 닉네임을 정해 주세요';
  end if;

  insert into picks(nickname, round, slot, numbers) values (p_nickname, p_round, p_slot, v_nums)
  on conflict (nickname, round, slot) do update set numbers = excluded.numbers, created_at = now();
end $$;

-- 번호 삭제 (마감 전 회차만)
create or replace function public.delete_pick(p_nickname text, p_key text, p_round int, p_slot int)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text;
begin
  select pin_hash into v_hash from players where nickname = btrim(p_nickname);
  if v_hash is null or crypt(p_key, v_hash) <> v_hash then raise exception '이 브라우저에서 저장한 번호만 지울 수 있어요'; end if;
  if now() >= public.round_close_at(p_round) then raise exception '추첨이 끝난 번호는 지울 수 없어요'; end if;
  delete from picks where nickname = btrim(p_nickname) and round = p_round and slot = p_slot;
end $$;

-- 닉네임 확인: new(처음), ok(이 브라우저 것), taken(다른 사람이 쓰는 중)
create or replace function public.check_player(p_nickname text, p_key text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text;
begin
  select pin_hash into v_hash from players where nickname = btrim(p_nickname);
  if v_hash is null then return 'new'; end if;
  if crypt(p_key, v_hash) = v_hash then return 'ok'; end if;
  return 'taken';
end $$;

revoke all on function public.save_pick(text,text,int,int,int[]), public.delete_pick(text,text,int,int), public.check_player(text,text) from public;
grant execute on function public.save_pick(text,text,int,int,int[]), public.delete_pick(text,text,int,int), public.check_player(text,text), public.open_round(), public.round_close_at(int) to anon, authenticated;
