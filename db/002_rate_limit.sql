-- Run after 001_init.sql
create table if not exists public.td_rate_limits(key text primary key,window_start timestamptz not null default now(),counter int not null default 0);
alter table public.td_rate_limits enable row level security;
revoke all on public.td_rate_limits from anon,authenticated;
create or replace function public.td_limit(p_key text,p_max int,p_window_seconds int) returns boolean language plpgsql security definer set search_path=public as $$
declare c int;begin
insert into public.td_rate_limits(key,window_start,counter) values(p_key,now(),1)
on conflict(key) do update set window_start=case when td_rate_limits.window_start<now()-make_interval(secs=>p_window_seconds) then now() else td_rate_limits.window_start end,counter=case when td_rate_limits.window_start<now()-make_interval(secs=>p_window_seconds) then 1 else td_rate_limits.counter+1 end returning counter into c;
return c<=p_max;
end $$;
revoke all on function public.td_limit(text,int,int) from public,anon,authenticated;
grant execute on function public.td_limit(text,int,int) to service_role;
-- Periodically purge stale throttle records:
-- delete from public.td_rate_limits where window_start < now()-interval '1 day';
