-- 업데이트 4: 닉네임 욕설 필터
-- update-3.sql 다음에 SQL Editor 에 붙여 넣고 Run 하세요. 여러 번 실행해도 안전하고 기존 데이터는 그대로 둡니다.
--
-- 금지어는 Table Editor 의 banned_words 표에서 직접 추가·삭제할 수 있습니다.
--  - 닉네임에서 띄어쓰기·숫자·기호를 뺀 뒤 금지어가 들어 있으면 막습니다. (예: "시 1 발" → "시발")
--  - 금지어를 새로 추가하면, 이미 그 단어를 쓰던 닉네임도 모두의 히스토리 목록에서 바로 숨겨집니다.

create table if not exists public.banned_words (
  word text primary key check (word = lower(word) and char_length(word) between 1 and 30),
  created_at timestamptz not null default now()
);
alter table public.banned_words enable row level security;
revoke all on public.banned_words from anon, authenticated;

insert into public.banned_words(word) values
  -- 욕설
  ('씨발'),('시발'),('씌발'),('씨바'),('시바'),('ㅅㅂ'),('ㅆㅂ'),('ㅅㅂㄹㅁ'),('씨팔'),('시팔'),('쓰발'),
  ('병신'),('븅신'),('빙신'),('ㅂㅅ'),('ㅄ'),('좆'),('좃'),('존나'),('졸라'),('ㅈㄴ'),
  ('개새'),('개색'),('새끼'),('새기'),('ㅅㄲ'),('지랄'),('ㅈㄹ'),('염병'),('엠창'),('니미'),('느금'),('니애미'),('애미'),('애비'),
  ('미친놈'),('미친년'),('또라이'),('똘아이'),('꺼져'),('닥쳐'),('등신'),('찐따'),('한남'),('김치녀'),('된장녀'),
  -- 성적 표현
  ('섹스'),('보지'),('자지'),('강간'),('야동'),
  -- 영어
  ('fuck'),('shit'),('bitch'),('asshole'),('dick'),('pussy'),('nigger'),('nigga'),('porn'),('sex'),
  -- 운영자 사칭
  ('운영자'),('관리자'),('admin'),('동행복권')
on conflict do nothing;

create or replace function public.is_bad_nickname(p_nickname text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from banned_words
    where position(word in regexp_replace(lower(coalesce(p_nickname, '')), '[^가-힣ㄱ-ㅎㅏ-ㅣa-z]', '', 'g')) > 0
  )
$$;
revoke all on function public.is_bad_nickname(text) from public;
grant execute on function public.is_bad_nickname(text) to anon, authenticated;  -- 목록(view)에서 쓰므로 필요 (참/거짓만 돌려줌)

-- 목록: 금지어가 들어간 닉네임은 숨김
create or replace view public.shared_picks as
  select left(p.owner, 8) as uid, p.nickname, p.round, p.slot, p.numbers
  from public.picks p
  where p.nickname is not null and not public.is_bad_nickname(p.nickname);
grant select on public.shared_picks to anon, authenticated;

-- 닉네임 정하기·바꾸기: 금지어가 있으면 거절
create or replace function public.set_nickname(p_key text, p_nickname text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_owner text := public._owner(p_key);
begin
  p_nickname := btrim(p_nickname);
  if char_length(p_nickname) not between 1 and 12 then raise exception '닉네임은 1~12자로 정해 주세요'; end if;
  if public.is_bad_nickname(p_nickname) then raise exception '사용할 수 없는 단어가 들어 있어요. 다른 닉네임을 정해 주세요'; end if;
  insert into players(owner, nickname) values (v_owner, p_nickname)
  on conflict (owner) do update set nickname = excluded.nickname, updated_at = now();
  update picks set nickname = p_nickname where owner = v_owner and now() < public.round_close_at(round);
end $$;

-- 번호 저장: 닉네임에 금지어가 있으면 번호는 익명으로만 저장
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
  if coalesce(btrim(p_nickname), '') <> '' and not public.is_bad_nickname(p_nickname) then
    perform public.set_nickname(p_key, p_nickname);
  else
    insert into players(owner, nickname) values (v_owner, null) on conflict (owner) do nothing;
  end if;
  select nickname into v_nick from players where owner = v_owner;
  if public.is_bad_nickname(v_nick) then v_nick := null; end if;
  insert into picks(owner, round, slot, numbers, nickname) values (v_owner, p_round, p_slot, v_nums, v_nick)
  on conflict (owner, round, slot) do update set numbers = excluded.numbers, nickname = excluded.nickname, created_at = now();
end $$;

grant execute on function public.set_nickname(text,text), public.save_pick(text,text,int,int,int[]) to anon, authenticated;
