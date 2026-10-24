-- 업데이트 6: 익명 봇 5개가 매 회차 5게임씩 무작위 번호 저장
-- update-5.sql 다음에 SQL Editor 에 붙여 넣고 Run 하세요. 여러 번 실행해도 안전합니다.
--  - 봇은 닉네임이 없어서 '모두의 히스토리' 목록엔 안 보이고, 전체 통계(저장 인원·등수별 게임 수)에만 들어갑니다.
--  - 봇 열쇠는 아무도 모르는 무작위 값이라 사이트에서 봇 번호를 바꾸거나 지울 수 없습니다.
--  - Supabase 안의 예약 작업(pg_cron)이 매시 17분에 확인해서, 새 회차가 열렸는데 봇 번호가 없으면 채웁니다.

create extension if not exists pg_cron with schema pg_catalog;

create table if not exists public.bot_owners (
  owner text primary key
);
alter table public.bot_owners enable row level security;
revoke all on public.bot_owners from anon, authenticated;

-- 봇 5개 만들기 (이미 있으면 그대로)
insert into public.bot_owners(owner)
select encode(extensions.gen_random_bytes(32), 'hex') from generate_series(1, 5 - (select count(*) from public.bot_owners)::int);
insert into public.players(owner, nickname) select owner, null from public.bot_owners on conflict (owner) do nothing;

-- 지금 열린 회차에 봇 번호 채우기 (이미 있는 자리는 그대로)
create or replace function public.bot_fill()
returns int language plpgsql security definer set search_path = public, extensions as $$
declare v_round int := public.open_round(); b record; s int; v_nums smallint[]; n int := 0;
begin
  for b in select owner from bot_owners loop
    for s in 0..4 loop
      if not exists (select 1 from picks where owner = b.owner and round = v_round and slot = s) then
        select array_agg(x order by x)::smallint[] into v_nums
          from (select x from generate_series(1, 45) x order by random() limit 6) t;
        insert into picks(owner, round, slot, numbers, nickname) values (b.owner, v_round, s, v_nums, null)
        on conflict (owner, round, slot) do nothing;
        n := n + 1;
      end if;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.bot_fill() from public, anon, authenticated;

-- 매시 17분에 확인 (같은 이름으로 다시 등록하면 바뀐 내용으로 덮어씀)
select cron.schedule('lopop-bot-fill', '17 * * * *', 'select public.bot_fill()');

-- 지금 회차 바로 채우기
select public.bot_fill() as "새로 저장한 봇 게임 수";
