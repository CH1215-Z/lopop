-- 업데이트 2: 사이트 전체 당첨 통계
-- 이미 setup.sql 을 실행한 프로젝트에서 SQL Editor 에 붙여 넣고 Run 하세요. 기존 데이터는 그대로 둡니다.
--  - 닉네임 없이도 이번 회차 번호를 익명으로 모읍니다 (모두의 히스토리 목록에는 닉네임 있는 사람만 보임)
--  - 회차별로 이 사이트에서 뽑은 번호가 몇 등에 몇 게임 당첨됐는지 셉니다

alter table public.players alter column nickname drop not null;

-- 목록에는 닉네임을 정한 사람만
create or replace view public.shared_picks as
  select left(p.owner, 8) as uid, pl.nickname, p.round, p.slot, p.numbers
  from public.picks p join public.players pl using (owner)
  where pl.nickname is not null;
grant select on public.shared_picks to anon, authenticated;

-- 번호 저장: 닉네임이 비어 있으면 익명으로 저장 (이미 정한 닉네임은 건드리지 않음)
create or replace function public.save_pick(p_key text, p_nickname text, p_round int, p_slot int, p_numbers int[])
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
  if coalesce(btrim(p_nickname), '') <> '' then
    perform public.set_nickname(p_key, p_nickname);
  else
    insert into players(owner, nickname) values (v_owner, null) on conflict (owner) do nothing;
  end if;
  insert into picks(owner, round, slot, numbers) values (v_owner, p_round, p_slot, v_nums)
  on conflict (owner, round, slot) do update set numbers = excluded.numbers, created_at = now();
end $$;

-- 공유 끄기: 닉네임만 지우고 번호는 익명 통계로 남김
create or replace function public.clear_nickname(p_key text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  update players set nickname = null, updated_at = now() where owner = public._owner(p_key);
end $$;

-- 회차 통계: 그 회차 당첨번호를 넣으면 등수별 게임 수를 돌려줍니다
create or replace function public.round_stats(p_round int, p_win int[], p_bonus int)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'total', count(*),
    'r1', count(*) filter (where m = 6),
    'r2', count(*) filter (where m = 5 and b),
    'r3', count(*) filter (where m = 5 and not b),
    'r4', count(*) filter (where m = 4),
    'r5', count(*) filter (where m = 3),
    'people', count(distinct owner))
  from (select owner, (select count(*) from unnest(numbers) x where x = any(p_win)) as m, p_bonus = any(numbers) as b
        from picks where round = p_round) s
$$;

revoke all on function public.clear_nickname(text), public.round_stats(int,int[],int) from public;
grant execute on function public.save_pick(text,text,int,int,int[]), public.clear_nickname(text), public.round_stats(int,int[],int) to anon, authenticated;
