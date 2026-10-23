-- 업데이트 3: 회차마다 그때의 닉네임을 그대로 남기기
-- update-2.sql 다음에 SQL Editor 에 붙여 넣고 Run 하세요. 여러 번 실행해도 안전하고 기존 데이터는 그대로 둡니다.
--  - 번호마다 저장할 때의 닉네임을 함께 기록합니다.
--  - 닉네임을 바꾸거나 공유를 끄면, 아직 판매 마감 전인 회차에만 적용됩니다. 추첨이 끝난 회차 기록은 그때 이름 그대로 남습니다.

alter table public.picks add column if not exists nickname text;

-- 지금까지 저장된 번호에는 현재 닉네임을 채워 둡니다 (한 번만)
update public.picks p set nickname = pl.nickname
from public.players pl
where pl.owner = p.owner and p.nickname is null and pl.nickname is not null;

create or replace view public.shared_picks as
  select left(p.owner, 8) as uid, p.nickname, p.round, p.slot, p.numbers
  from public.picks p
  where p.nickname is not null;
grant select on public.shared_picks to anon, authenticated;

-- 닉네임 정하기·바꾸기: 마감 전 회차 번호에만 새 이름 적용
create or replace function public.set_nickname(p_key text, p_nickname text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_owner text := public._owner(p_key);
begin
  p_nickname := btrim(p_nickname);
  if char_length(p_nickname) not between 1 and 12 then raise exception '닉네임은 1~12자로 정해 주세요'; end if;
  insert into players(owner, nickname) values (v_owner, p_nickname)
  on conflict (owner) do update set nickname = excluded.nickname, updated_at = now();
  update picks set nickname = p_nickname where owner = v_owner and now() < public.round_close_at(round);
end $$;

-- 공유 끄기: 마감 전 회차 번호만 목록에서 빠지고, 지난 기록은 그대로
create or replace function public.clear_nickname(p_key text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_owner text := public._owner(p_key);
begin
  update players set nickname = null, updated_at = now() where owner = v_owner;
  update picks set nickname = null where owner = v_owner and now() < public.round_close_at(round);
end $$;

-- 번호 저장: 그 순간의 닉네임을 함께 기록
create or replace function public.save_pick(p_key text, p_nickname text, p_round int, p_slot int, p_numbers int[])
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_owner text := public._owner(p_key); v_nums smallint[]; v_nick text;
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
  select nickname into v_nick from players where owner = v_owner;
  insert into picks(owner, round, slot, numbers, nickname) values (v_owner, p_round, p_slot, v_nums, v_nick)
  on conflict (owner, round, slot) do update set numbers = excluded.numbers, nickname = excluded.nickname, created_at = now();
end $$;

grant execute on function public.set_nickname(text,text), public.clear_nickname(text), public.save_pick(text,text,int,int,int[]) to anon, authenticated;
