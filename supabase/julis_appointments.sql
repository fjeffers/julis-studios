-- Juli's Studios: 1-hour appointment booking. Availability lives in
-- julis_settings.data.schedule = {"weekly": {"5": [["10:30","15:00"]], ...},
-- "blackouts": ["YYYY-MM-DD", ...], "slotMinutes": 60} (weekday 0 = Sunday,
-- times in America/Chicago). Customer details are never publicly readable.
-- Safe to re-run.

create table if not exists public.julis_appointments (
  id          bigserial primary key,
  start_at    timestamptz not null,
  name        text not null,
  phone       text not null,
  email       text not null,
  status      text not null default 'booked' check (status in ('booked', 'cancelled')),
  email_token text,
  created_at  timestamptz not null default now()
);
create unique index if not exists julis_appointments_one_per_slot
  on public.julis_appointments (start_at) where status = 'booked';
alter table public.julis_appointments enable row level security;
revoke all on public.julis_appointments from anon, authenticated;

create table if not exists public.julis_booking_attempts (
  client text not null,
  at     timestamptz not null default now()
);
create index if not exists julis_booking_attempts_client_at on public.julis_booking_attempts (client, at);
alter table public.julis_booking_attempts enable row level security;
revoke all on public.julis_booking_attempts from anon, authenticated;

create or replace function public.julis_schedule()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce((select data->'schedule' from public.julis_settings where id = 1), '{}'::jsonb);
$$;

-- Booked start times (no customer details) between two instants, max 120 days.
create or replace function public.julis_booked_slots(p_from timestamptz, p_to timestamptz)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(start_at order by start_at), '[]'::jsonb)
    from public.julis_appointments
   where status = 'booked'
     and start_at >= p_from and start_at < p_to
     and p_to - p_from <= interval '120 days';
$$;

-- Books one slot. Returns {"id": ..., "token": ...}; the token lets the booking
-- page trigger the confirmation email once. Raises P0001 with a readable message.
create or replace function public.julis_book_appointment(
  p_start timestamptz, p_name text, p_phone text, p_email text)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions
as $$
declare
  k text := coalesce(nullif(trim(split_part(
    coalesce(nullif(current_setting('request.headers', true), '')::json->>'x-forwarded-for', ''),
    ',', 1)), ''), 'unknown');
  n text := trim(coalesce(p_name, ''));
  ph text := trim(coalesce(p_phone, ''));
  em text := lower(trim(coalesce(p_email, '')));
  sched jsonb := public.julis_schedule();
  slot int := least(240, greatest(15, coalesce((sched->>'slotMinutes')::int, 60)));
  local_ts timestamp;
  local_t time;
  windows jsonb;
  w jsonb;
  ok boolean := false;
  new_id bigint;
  tok text := encode(gen_random_bytes(18), 'hex');
begin
  if p_start is null then
    raise exception 'Please pick a time.' using errcode = 'P0001';
  end if;
  if char_length(n) < 1 or char_length(n) > 60 then
    raise exception 'Please enter your name (up to 60 characters).' using errcode = 'P0001';
  end if;
  if ph !~ '^[0-9+() .-]{7,20}$' or char_length(regexp_replace(ph, '\D', '', 'g')) < 7 then
    raise exception 'Please enter a valid phone number.' using errcode = 'P0001';
  end if;
  if char_length(em) > 120 or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Please enter a valid email address.' using errcode = 'P0001';
  end if;
  if p_start < now() + interval '1 hour' or p_start > now() + interval '120 days' then
    raise exception 'That time is no longer available.' using errcode = 'P0001';
  end if;

  local_ts := p_start at time zone 'America/Chicago';
  local_t := local_ts::time;
  if extract(second from local_ts) <> 0 then
    raise exception 'That time is not available.' using errcode = 'P0001';
  end if;
  if coalesce(sched->'blackouts', '[]'::jsonb) ? to_char(local_ts::date, 'YYYY-MM-DD') then
    raise exception 'Juli is not taking appointments that day.' using errcode = 'P0001';
  end if;
  windows := case when sched ? 'weekly'
                  then coalesce(sched->'weekly'->(extract(dow from local_ts)::int::text), '[]'::jsonb)
                  when extract(dow from local_ts)::int in (5, 6) then '[["10:30","15:00"]]'::jsonb
                  else '[]'::jsonb end;
  for w in select * from jsonb_array_elements(windows) loop
    if local_t >= (w->>0)::time
       and local_t + make_interval(mins => slot) > local_t
       and local_t + make_interval(mins => slot) <= (w->>1)::time
       and (extract(epoch from local_t - (w->>0)::time) / 60)::int % slot = 0 then
      ok := true;
    end if;
  end loop;
  if not ok then
    raise exception 'That time is not available.' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtext('julis_booking:' || k));
  if (select count(*) from public.julis_booking_attempts
       where client = k and at > now() - interval '1 hour') >= 3 then
    raise exception 'Too many bookings, please try again later.' using errcode = 'P0001';
  end if;
  insert into public.julis_booking_attempts (client) values (k);
  delete from public.julis_booking_attempts where at < now() - interval '1 day';

  perform pg_advisory_xact_lock(hashtext('julis_booking_calendar'));
  if exists (select 1 from public.julis_appointments
              where status = 'booked'
                and start_at > p_start - make_interval(mins => slot)
                and start_at < p_start + make_interval(mins => slot)) then
    raise exception 'Sorry, someone just booked that time. Please pick another.' using errcode = 'P0001';
  end if;

  begin
    insert into public.julis_appointments (start_at, name, phone, email, email_token)
    values (p_start, n, ph, em, tok)
    returning id into new_id;
  exception when unique_violation then
    raise exception 'Sorry, someone just booked that time. Please pick another.' using errcode = 'P0001';
  end;
  return jsonb_build_object('id', new_id, 'token', tok);
end;
$$;

-- One-time read for the confirmation email: returns the booking and burns the
-- token, or null if the id/token pair is wrong or was already used.
create or replace function public.julis_appointment_for_email(p_id bigint, p_token text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  r public.julis_appointments;
begin
  update public.julis_appointments
     set email_token = null
   where id = p_id and email_token is not null and email_token = p_token
         and status = 'booked'
  returning * into r;
  if r.id is null then
    return null;
  end if;
  return jsonb_build_object('id', r.id, 'start_at', r.start_at, 'name', r.name,
                            'phone', r.phone, 'email', r.email);
end;
$$;

-- All appointments (upcoming first), or null when the password is wrong or locked out.
create or replace function public.julis_admin_appointments(p_passcode text)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions
as $$
begin
  if not public.julis_check_passcode(p_passcode) then
    return null;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', a.id, 'start_at', a.start_at, 'name', a.name,
                                        'phone', a.phone, 'email', a.email, 'status', a.status,
                                        'created_at', a.created_at)
                     order by (a.start_at < now()), a.start_at)
      from public.julis_appointments a
     where a.start_at > now() - interval '60 days'), '[]'::jsonb);
end;
$$;

-- Cancels a booking (frees the slot). False when the password is wrong or locked out.
create or replace function public.julis_cancel_appointment(p_passcode text, p_id bigint)
returns boolean
language plpgsql volatile security definer set search_path = public, extensions
as $$
begin
  if not public.julis_check_passcode(p_passcode) then
    return false;
  end if;
  update public.julis_appointments set status = 'cancelled', email_token = null where id = p_id;
  return true;
end;
$$;

revoke all on function public.julis_schedule()                                       from public;
revoke all on function public.julis_booked_slots(timestamptz, timestamptz)           from public;
revoke all on function public.julis_book_appointment(timestamptz, text, text, text)  from public;
revoke all on function public.julis_appointment_for_email(bigint, text)              from public;
revoke all on function public.julis_admin_appointments(text)                         from public;
revoke all on function public.julis_cancel_appointment(text, bigint)                 from public;
grant execute on function public.julis_booked_slots(timestamptz, timestamptz)          to anon, authenticated;
grant execute on function public.julis_book_appointment(timestamptz, text, text, text) to anon, authenticated;
grant execute on function public.julis_appointment_for_email(bigint, text)             to anon, authenticated;
grant execute on function public.julis_admin_appointments(text)                        to anon, authenticated;
grant execute on function public.julis_cancel_appointment(text, bigint)                to anon, authenticated;
