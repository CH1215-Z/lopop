-- 업데이트 5: 다른 기기 연결 (내 번호·가진 번호·히스토리·닉네임을 기기끼리 맞추기)
-- update-4.sql 다음에 SQL Editor 에 붙여 넣고 Run 하세요. 여러 번 실행해도 안전하고 기존 데이터는 그대로 둡니다.
--  - 연결된 기기의 기록은 user_state 표에 비공개로 보관됩니다. (다른 사람은 읽을 수 없음)
--  - 연결 코드는 8자리이고 10분 뒤 또는 한 번 쓰면 사라집니다.

create table if not exists public.user_state (
  owner      text primary key,             -- 브라우저 열쇠의 sha256
  data       jsonb not null,
  updated_at timestamptz not null default now()
);
create table if not exists public.link_codes (
  code       text primary key,
  owner      text not null,
  link_key   text not null,                -- 다른 기기에 넘겨줄 열쇠 (10분 동안만 보관)
  expires_at timestamptz not null
);
alter table public.user_state enable row level security;
alter table public.link_codes enable row level security;
revoke all on public.user_state from anon, authenticated;
revoke all on public.link_codes from anon, authenticated;

-- 내 기록 불러오기
create or replace function public.get_state(p_key text)
returns json language sql stable security definer set search_path = public, extensions as $$
  select json_build_object('data', data, 'updated_at', updated_at) from user_state where owner = public._owner(p_key)
$$;

-- 내 기록 저장하기 (p_prev 가 서버 값과 다르면 다른 기기가 먼저 바꾼 것이므로 저장하지 않고 null 반환)
create or replace function public.put_state(p_key text, p_data jsonb, p_prev timestamptz)
returns timestamptz language plpgsql security definer set search_path = public, extensions as $$
declare v_owner text := public._owner(p_key); v_cur timestamptz; v_now timestamptz := clock_timestamp();
begin
  if octet_length(p_data::text) > 200000 then raise exception '저장할 기록이 너무 커요'; end if;
  select updated_at into v_cur from user_state where owner = v_owner for update;
  if v_cur is not null and p_prev is not null and v_cur <> p_prev then return null; end if;
  insert into user_state(owner, data, updated_at) values (v_owner, p_data, v_now)
  on conflict (owner) do update set data = excluded.data, updated_at = excluded.updated_at;
  return v_now;
end $$;

-- 연결 코드 만들기 (기기마다 하나, 10분 유효)
create or replace function public.create_link_code(p_key text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_owner text := public._owner(p_key); v_code text; v_exp timestamptz := now() + interval '10 minutes';
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; i int;
begin
  delete from link_codes where expires_at < now() or owner = v_owner;
  loop
    v_code := '';
    for i in 1..8 loop v_code := v_code || substr(v_chars, 1 + (get_byte(gen_random_bytes(1), 0) % 32), 1); end loop;
    exit when not exists (select 1 from link_codes where code = v_code);
  end loop;
  insert into link_codes(code, owner, link_key, expires_at) values (v_code, v_owner, p_key, v_exp);
  return json_build_object('code', v_code, 'expires_at', v_exp);
end $$;

-- 연결 코드 쓰기: 맞으면 열쇠를 돌려주고 코드는 바로 지웁니다
create or replace function public.redeem_link_code(p_code text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_key text; v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  delete from link_codes where expires_at < now();
  delete from link_codes where code = v_code returning link_key into v_key;
  if v_key is null then
    perform pg_sleep(0.3);
    raise exception '코드가 맞지 않거나 시간이 지났어요. 원래 기기에서 새 코드를 만들어 주세요';
  end if;
  return v_key;
end $$;

revoke all on function public.get_state(text), public.put_state(text,jsonb,timestamptz), public.create_link_code(text), public.redeem_link_code(text) from public;
grant execute on function public.get_state(text), public.put_state(text,jsonb,timestamptz), public.create_link_code(text), public.redeem_link_code(text) to anon, authenticated;
