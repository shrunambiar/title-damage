-- Run once in Supabase SQL Editor. All application mutations are serialized by room row locks.
create extension if not exists pgcrypto;
create table if not exists public.movies(id text primary key,title text not null,year int not null,language text not null,industry text not null,genres text[] not null default '{}',popularity_tier int not null default 3,humor_score int not null default 3,normalized_title text not null,external_id text, family_friendly boolean not null default true);
create index if not exists movies_filter_idx on public.movies(industry,popularity_tier);
create table if not exists public.anonymous_hosts(id uuid primary key default gen_random_uuid(),session_hash text unique not null,created_at timestamptz not null default now());
create table if not exists public.rooms(id uuid primary key default gen_random_uuid(),code text not null unique,host_id uuid not null references public.anonymous_hosts(id),host_session_hash text not null,phase text not null default 'LOBBY',deadline timestamptz,round_number int not null default 0,movie_id text references public.movies(id),settings jsonb not null default '{"rounds":5,"submissionSeconds":30,"votingSeconds":20,"category":"All Movies","contentMode":"family","finale":true,"sound":true}',paused boolean not null default false,paused_remaining interval,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),expires_at timestamptz not null default now()+interval '8 hours');
create table if not exists public.room_players(id uuid primary key default gen_random_uuid(),room_id uuid not null references public.rooms(id) on delete cascade,nickname text not null,session_hash text not null unique,score numeric(12,6) not null default 0,joined_at timestamptz not null default now(),last_seen timestamptz not null default now());
create unique index if not exists unique_nick on public.room_players(room_id,lower(nickname));
create table if not exists public.game_rounds(id uuid primary key default gen_random_uuid(),room_id uuid not null references public.rooms(id) on delete cascade,round_number int not null,movie_id text not null references public.movies(id),scored boolean not null default false,unique(room_id,round_number),unique(room_id,movie_id));
create table if not exists public.movie_history(host_id uuid not null references public.anonymous_hosts(id) on delete cascade,movie_id text not null references public.movies(id),used_at timestamptz not null default now(),primary key(host_id,movie_id));
create index if not exists movie_history_order_idx on public.movie_history(host_id,used_at);
create table if not exists public.submissions(id uuid primary key default gen_random_uuid(),round_id uuid not null references public.game_rounds(id) on delete cascade,player_id uuid not null references public.room_players(id) on delete cascade,word text not null,insertion_index int not null,title text not null,reveal_order double precision not null default random(),votes int not null default 0,unique(round_id,player_id));
create table if not exists public.votes(id uuid primary key default gen_random_uuid(),round_id uuid not null references public.game_rounds(id) on delete cascade,voter_id uuid not null references public.room_players(id) on delete cascade,submission_id uuid not null references public.submissions(id) on delete cascade,unique(round_id,voter_id));
create table if not exists public.finale_votes(id uuid primary key default gen_random_uuid(),room_id uuid not null references public.rooms(id) on delete cascade,voter_id uuid not null references public.room_players(id) on delete cascade,submission_id uuid not null references public.submissions(id) on delete cascade,unique(room_id,voter_id));
create index if not exists room_player_idx on public.room_players(room_id);
create index if not exists room_round_idx on public.game_rounds(room_id);
create index if not exists submission_round_idx on public.submissions(round_id);
create index if not exists vote_round_idx on public.votes(round_id);
-- No direct client table access. Service role is used only by server routes.
alter table public.movies enable row level security;
alter table public.anonymous_hosts enable row level security;
alter table public.rooms enable row level security;
alter table public.room_players enable row level security;
alter table public.game_rounds enable row level security;
alter table public.movie_history enable row level security;
alter table public.submissions enable row level security;
alter table public.votes enable row level security;
alter table public.finale_votes enable row level security;
revoke all on all tables in schema public from anon,authenticated;

create or replace function public.td_eligible(p_category text,p_mode text,p_id text) returns boolean language sql stable as $$
select exists(select 1 from public.movies m where m.id=p_id and (p_mode<>'family' or m.family_friendly) and
case p_category
when 'Hollywood' then m.industry='Hollywood'
when 'Bollywood' then m.industry='Bollywood'
when 'South Indian' then m.industry in ('Tamil','Telugu','Malayalam','Kannada')
when 'Mixed Indian and Hollywood' then m.industry in ('Hollywood','Bollywood','Tamil','Telugu','Malayalam','Kannada')
when 'Comedy' then 'Comedy'=any(m.genres)
when 'Horror' then 'Horror'=any(m.genres)
when 'Family Friendly' then m.family_friendly
else true end);
$$;

create or replace function public.td_assign_movie(p_room uuid) returns void language plpgsql security definer set search_path=public as $$
declare r public.rooms%rowtype; next_id text; hc int;begin
select * into r from public.rooms where id=p_room for update;
-- Pick unseen host history first; when exhausted, reuse the least recently played eligible movie.
select m.id into next_id from public.movies m left join public.movie_history h on h.movie_id=m.id and h.host_id=r.host_id
where public.td_eligible(r.settings->>'category',r.settings->>'contentMode',m.id)
and not exists(select 1 from public.game_rounds gr where gr.room_id=r.id and gr.movie_id=m.id)
order by (h.used_at is not null),h.used_at asc nulls first,random() limit 1;
if next_id is null then raise exception 'No eligible unseen movies for this game; change category';end if;
insert into public.movie_history(host_id,movie_id,used_at) values(r.host_id,next_id,now()) on conflict(host_id,movie_id) do update set used_at=excluded.used_at;
insert into public.game_rounds(room_id,round_number,movie_id) values(r.id,r.round_number,next_id);
update public.rooms set movie_id=next_id,phase='REVEAL',deadline=now()+interval '4 seconds',updated_at=now() where id=r.id;
end $$;

create or replace function public.td_finalists(p_room uuid) returns table(submission_id uuid) language sql stable as $$
with ranked as (select s.id,s.votes,rank() over(partition by gr.id order by s.votes desc) as rk from public.submissions s join public.game_rounds gr on gr.id=s.round_id where gr.room_id=p_room)
select id from ranked where rk=1;
$$;

create or replace function public.td_progress(p_room uuid,p_force boolean default false) returns void language plpgsql security definer set search_path=public as $$
declare r public.rooms%rowtype; gr uuid; n int; needed int; eligible int; max_votes int; num_winners int; v record; finalists int;begin
select * into r from public.rooms where id=p_room for update;
if r.id is null or r.expires_at<now() or r.paused then return;end if;
if not p_force and (r.deadline is null or r.deadline>now()) then
  if r.phase='SUBMITTING' then
    select count(*) into n from public.submissions s join public.game_rounds g on g.id=s.round_id where g.room_id=r.id and g.round_number=r.round_number;
    select count(*) into needed from public.room_players where room_id=r.id;
    if n<needed then return;end if;
  elsif r.phase='VOTING' then
    select id into gr from public.game_rounds where room_id=r.id and round_number=r.round_number;
    select count(*) into n from public.votes where round_id=gr;
    select count(*) into needed from public.room_players p where p.room_id=r.id and exists(select 1 from public.submissions s where s.round_id=gr and s.player_id<>p.id);
    if n<needed then return;end if;
  elsif r.phase='FINALE_VOTING' then
    select count(*) into n from public.finale_votes where room_id=r.id;
    select count(*) into needed from public.room_players p where p.room_id=r.id and exists(select 1 from public.td_finalists(r.id) f join public.submissions s on s.id=f.submission_id where s.player_id<>p.id);
    if n<needed then return;end if;
  else return;end if;
end if;
if r.phase='REVEAL' then
 update public.rooms set phase='SUBMITTING',deadline=now()+make_interval(secs=>(r.settings->>'submissionSeconds')::int) where id=r.id;
elsif r.phase='SUBMITTING' then
 select id into gr from public.game_rounds where room_id=r.id and round_number=r.round_number;
 select count(*) into n from public.submissions where round_id=gr;
 if n<2 then
  update public.rooms set phase='RESULTS',deadline=now()+interval '8 seconds' where id=r.id;
 else
  update public.rooms set phase='SUBMISSION_REVEAL',deadline=now()+interval '5 seconds' where id=r.id;
 end if;
elsif r.phase='SUBMISSION_REVEAL' then
 update public.rooms set phase='VOTING',deadline=now()+make_interval(secs=>(r.settings->>'votingSeconds')::int) where id=r.id;
elsif r.phase='VOTING' then
 select id into gr from public.game_rounds where room_id=r.id and round_number=r.round_number;
 if not (select scored from public.game_rounds where id=gr) then
   update public.submissions s set votes=(select count(*) from public.votes v where v.submission_id=s.id) where s.round_id=gr;
   select max(votes) into max_votes from public.submissions where round_id=gr;
   select count(*) into num_winners from public.submissions where round_id=gr and votes=max_votes;
   update public.room_players p set score=p.score+coalesce((select sum(s.votes*100+case when max_votes>0 and s.votes=max_votes then 200::numeric/num_winners else 0 end) from public.submissions s where s.round_id=gr and s.player_id=p.id),0) where p.room_id=r.id;
   update public.game_rounds set scored=true where id=gr;
 end if;
 update public.rooms set phase='RESULTS',deadline=now()+interval '8 seconds' where id=r.id;
elsif r.phase='RESULTS' then
 update public.rooms set phase='LEADERBOARD',deadline=now()+interval '6 seconds' where id=r.id;
elsif r.phase='LEADERBOARD' then
 if r.round_number < (r.settings->>'rounds')::int then
  update public.rooms set round_number=round_number+1 where id=r.id;
  perform public.td_assign_movie(r.id);
 elsif coalesce((r.settings->>'finale')::boolean,true) then
  update public.rooms set phase='FINALE_REVEAL',deadline=now()+interval '8 seconds',movie_id=null where id=r.id;
 else update public.rooms set phase='FINISHED',deadline=null,movie_id=null where id=r.id;end if;
elsif r.phase='FINALE_REVEAL' then
 select count(*) into finalists from public.td_finalists(r.id);
 if finalists<2 then update public.rooms set phase='FINALE_RESULTS',deadline=now()+interval '10 seconds' where id=r.id;
 else update public.rooms set phase='FINALE_VOTING',deadline=now()+interval '30 seconds' where id=r.id;end if;
elsif r.phase='FINALE_VOTING' then
 update public.rooms set phase='FINALE_RESULTS',deadline=now()+interval '10 seconds' where id=r.id;
elsif r.phase='FINALE_RESULTS' then
 update public.rooms set phase='FINISHED',deadline=null where id=r.id;
end if;
update public.rooms set updated_at=now() where id=r.id;
end $$;

create or replace function public.td_action(p_code text,p_auth text,p_action text,p_data jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.rooms%rowtype; p public.room_players%rowtype; h boolean; gr uuid; target public.submissions%rowtype; w text; idx int; parts text[]; original text; new_title text; cname text; cfg jsonb; n int;begin
select * into r from public.rooms where code=upper(p_code) for update;
if r.id is null or r.expires_at<now() then raise exception 'Room not found or expired';end if;
h=r.host_session_hash=p_auth;
if not h then select * into p from public.room_players where room_id=r.id and session_hash=p_auth;end if;
if not h and p.id is null then raise exception 'Forbidden: invalid session';end if;
if p_action='join' then raise exception 'Invalid action';end if;
perform public.td_progress(r.id);
select * into r from public.rooms where id=r.id;
if p_action='start' then
 if not h or r.phase<>'LOBBY' then raise exception 'Not allowed to start';end if;
 select count(*) into n from public.room_players where room_id=r.id;
 if n<3 then raise exception 'Too few players (minimum 3)';end if;
 update public.rooms set round_number=1 where id=r.id;perform public.td_assign_movie(r.id);
elsif p_action='settings' then
 if not h or r.phase<>'LOBBY' then raise exception 'Not allowed to change settings';end if;
 cfg=p_data;
 if (cfg->>'rounds')::int not in (3,5,10) or (cfg->>'submissionSeconds')::int not in (20,30,45,60) or (cfg->>'votingSeconds')::int not in (15,20,30) or cfg->>'contentMode' not in ('family','adult') or cfg->>'category' not in ('All Movies','Hollywood','Bollywood','South Indian','Mixed Indian and Hollywood','Comedy','Horror','Family Friendly','Custom Genre Mix') or jsonb_typeof(cfg->'finale')<>'boolean' or jsonb_typeof(cfg->'sound')<>'boolean' then raise exception 'Invalid settings';end if;
 update public.rooms set settings=cfg where id=r.id;
elsif p_action='submit' then
 if p.id is null or r.phase<>'SUBMITTING' or r.deadline<=now() or r.paused then raise exception 'Submission deadline passed or invalid phase';end if;
 w=p_data->>'word'; idx=(p_data->>'index')::int;
 if w is null or length(w)>40 or w ~ '[[:space:]<>]' or w !~ '.' then raise exception 'Invalid one-word submission';end if;
 if r.settings->>'contentMode'='family' and w ~* '^(fuck|fucking|shit|bitch|cunt|nigger|nigga|faggot|rape|rapist|porn|porno|sex|sexual|dick|pussy|cock|asshole)$' then raise exception 'This word is not allowed in family-friendly mode';end if;
 select title into original from public.movies where id=r.movie_id;
 parts=regexp_split_to_array(original,'\s+');
 if idx<0 or idx>array_length(parts,1) then raise exception 'Invalid insertion index';end if;
 new_title=array_to_string(parts[1:idx],' ')||case when idx>0 then ' ' else '' end||w||case when idx<array_length(parts,1) then ' ' else '' end||coalesce(array_to_string(parts[idx+1:array_length(parts,1)],' '),'');
 select id into gr from public.game_rounds where room_id=r.id and round_number=r.round_number;
 insert into public.submissions(round_id,player_id,word,insertion_index,title) values(gr,p.id,w,idx,new_title) on conflict(round_id,player_id) do nothing;
 if not found then raise exception 'Already submitted';end if;
 perform public.td_progress(r.id);
elsif p_action='vote' then
 if p.id is null or r.phase<>'VOTING' or r.deadline<=now() or r.paused then raise exception 'Vote deadline passed or invalid phase';end if;
 select id into gr from public.game_rounds where room_id=r.id and round_number=r.round_number;
 select * into target from public.submissions where id=(p_data->>'submissionId')::uuid and round_id=gr;
 if target.id is null or target.player_id=p.id then raise exception 'Not eligible to vote for this entry';end if;
 insert into public.votes(round_id,voter_id,submission_id) values(gr,p.id,target.id) on conflict(round_id,voter_id) do nothing;
 if not found then raise exception 'Already voted';end if;
 perform public.td_progress(r.id);
elsif p_action='finaleVote' then
 if p.id is null or r.phase<>'FINALE_VOTING' or r.deadline<=now() or r.paused then raise exception 'Finale vote deadline passed or invalid phase';end if;
 select * into target from public.submissions where id=(p_data->>'submissionId')::uuid and id in(select submission_id from public.td_finalists(r.id));
 if target.id is null or target.player_id=p.id then raise exception 'Not eligible to vote for this finalist';end if;
 insert into public.finale_votes(room_id,voter_id,submission_id) values(r.id,p.id,target.id) on conflict(room_id,voter_id) do nothing;
 if not found then raise exception 'Already voted';end if;
 perform public.td_progress(r.id);
elsif p_action='advance' then
 if not h then raise exception 'Forbidden host action';end if;
 if r.phase in ('LOBBY','FINISHED') then raise exception 'Cannot advance this phase';end if;
 perform public.td_progress(r.id,true);
elsif p_action='skip' then
 if not h or r.phase<>'REVEAL' then raise exception 'Can only skip before submission';end if;
 -- drop unused round and choose another, retaining the skipped title in host history.
 delete from public.game_rounds where room_id=r.id and round_number=r.round_number;
 perform public.td_assign_movie(r.id);
elsif p_action='pause' then
 if not h or r.phase in ('LOBBY','FINISHED') then raise exception 'Cannot pause';end if;
 if r.paused then update public.rooms set paused=false,deadline=now()+coalesce(r.paused_remaining,interval '0 seconds'),paused_remaining=null where id=r.id;
 else update public.rooms set paused=true,paused_remaining=greatest(r.deadline-now(),interval '0 seconds') where id=r.id;end if;
elsif p_action='end' then
 if not h then raise exception 'Forbidden';end if;
 update public.rooms set phase='FINISHED',deadline=null,paused=false where id=r.id;
elsif p_action='rematch' then
 if not h or r.phase<>'FINISHED' then raise exception 'Can only rematch a finished game';end if;
 -- Delete old game rounds, but retain scores only after resetting, and preserve host movie history.
 delete from public.finale_votes where room_id=r.id;
 delete from public.game_rounds where room_id=r.id;
 update public.room_players set score=0 where room_id=r.id;
 update public.rooms set phase='LOBBY',round_number=0,movie_id=null,deadline=null,paused=false where id=r.id;
else raise exception 'Unknown action';end if;
return jsonb_build_object('ok',true);
end $$;

create or replace function public.td_join(p_code text,p_hash text,p_nickname text) returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.rooms%rowtype; n int; pid uuid;begin
select * into r from public.rooms where code=upper(p_code) for update;
if r.id is null or r.expires_at<now() then raise exception 'Room not found or expired';end if;
if r.phase<>'LOBBY' then raise exception 'Game already started';end if;
if p_nickname is null or length(trim(p_nickname))<1 or length(p_nickname)>20 or p_nickname !~ '^[[:alnum:] _-]+$' then raise exception 'Invalid nickname (1-20 letters/numbers)';end if;
select count(*) into n from public.room_players where room_id=r.id;
if n>=10 then raise exception 'Room full';end if;
if exists(select 1 from public.room_players where room_id=r.id and lower(nickname)=lower(trim(p_nickname))) then raise exception 'Nickname already taken';end if;
insert into public.room_players(room_id,nickname,session_hash) values(r.id,trim(p_nickname),p_hash) returning id into pid;
return jsonb_build_object('playerId',pid);
end $$;

create or replace function public.td_view(p_code text,p_auth text) returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.rooms%rowtype; p public.room_players%rowtype; h boolean; gr uuid; movie_title text; items jsonb='[]'; player_items jsonb; submitted boolean=false; voted boolean=false; eligible int=0; vote_count int=0; submission_count int=0; win_ids jsonb='[]'; finale_wins jsonb='[]'; remaining int; reveal boolean; item record;begin
select * into r from public.rooms where code=upper(p_code);
if r.id is null or r.expires_at<now() then raise exception 'Room not found or expired';end if;
h=coalesce(r.host_session_hash=p_auth,false);
if not h then select * into p from public.room_players where room_id=r.id and session_hash=p_auth;end if;
if not h and p.id is null then raise exception 'Forbidden: invalid session';end if;
perform public.td_progress(r.id);
select * into r from public.rooms where id=r.id;
if p.id is not null then update public.room_players set last_seen=now() where id=p.id;end if;
select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'nickname',q.nickname,'score',q.score,'connected',q.last_seen>now()-interval '45 seconds') order by q.score desc,q.joined_at), '[]'::jsonb) into player_items from public.room_players q where q.room_id=r.id;
select title into movie_title from public.movies where id=r.movie_id;
select id into gr from public.game_rounds where room_id=r.id and round_number=r.round_number;
select count(*) into submission_count from public.submissions where round_id=gr;
select count(*) into eligible from public.room_players q where q.room_id=r.id and exists(select 1 from public.submissions s where s.round_id=gr and s.player_id<>q.id);
select count(*) into vote_count from public.votes where round_id=gr;
if r.phase in ('FINALE_REVEAL','FINALE_VOTING','FINALE_RESULTS','FINISHED') and (r.settings->>'finale')::boolean then
select count(*) into eligible from public.room_players q where q.room_id=r.id and exists(select 1 from public.td_finalists(r.id) f join public.submissions s on s.id=f.submission_id where s.player_id<>q.id);
select count(*) into vote_count from public.finale_votes where room_id=r.id;
end if;
if p.id is not null then
select exists(select 1 from public.submissions where round_id=gr and player_id=p.id) into submitted;
select exists(select 1 from public.votes where round_id=gr and voter_id=p.id) into voted;
if r.phase in ('FINALE_REVEAL','FINALE_VOTING','FINALE_RESULTS','FINISHED') then select exists(select 1 from public.finale_votes where room_id=r.id and voter_id=p.id) into voted;end if;
end if;
if r.phase in ('SUBMISSION_REVEAL','VOTING','RESULTS','LEADERBOARD','FINALE_REVEAL','FINALE_VOTING','FINALE_RESULTS','FINISHED') then
 if r.phase in ('FINALE_REVEAL','FINALE_VOTING','FINALE_RESULTS','FINISHED') and (r.settings->>'finale')::boolean then
  select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'title',s.title,'original',m.title,'roundNumber',g.round_number,'isOwn',s.player_id=p.id,
    'author',case when r.phase in ('FINALE_RESULTS','FINISHED') then rp.nickname else null end,
    'votes',case when r.phase in ('FINALE_RESULTS','FINISHED') then (select count(*) from public.finale_votes fv where fv.submission_id=s.id) else null end) order by g.round_number,s.reveal_order),'[]') into items
  from public.td_finalists(r.id) f join public.submissions s on s.id=f.submission_id join public.game_rounds g on g.id=s.round_id join public.movies m on m.id=g.movie_id join public.room_players rp on rp.id=s.player_id;
  select coalesce(jsonb_agg(z.id),'[]') into finale_wins from (select fv.submission_id as id,count(*) as v from public.finale_votes fv where fv.room_id=r.id group by fv.submission_id having count(*)=(select max(c) from (select count(*) as c from public.finale_votes where room_id=r.id group by submission_id) x)) z;
 else
  select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'title',s.title,'isOwn',s.player_id=p.id,
    'author',case when r.phase in ('RESULTS','LEADERBOARD','FINISHED') then rp.nickname else null end,
    'votes',case when r.phase in ('RESULTS','LEADERBOARD','FINISHED') then s.votes else null end) order by s.reveal_order),'[]') into items
  from public.submissions s join public.room_players rp on rp.id=s.player_id where s.round_id=gr;
  if r.phase in ('RESULTS','LEADERBOARD','FINISHED') then
  select coalesce(jsonb_agg(s.id),'[]') into win_ids from public.submissions s where s.round_id=gr and s.votes>0 and s.votes=(select max(votes) from public.submissions where round_id=gr);
  end if;
 end if;
end if;
select count(*) into remaining from public.movies m where public.td_eligible(r.settings->>'category',r.settings->>'contentMode',m.id) and not exists(select 1 from public.movie_history mh where mh.host_id=r.host_id and mh.movie_id=m.id);
return jsonb_build_object('code',r.code,'phase',r.phase,'deadline',r.deadline,'serverTime',now(),'settings',r.settings,'players',player_items,'roundNumber',r.round_number,'movie',movie_title,'submissionsReceived',submission_count,'votesReceived',vote_count,'eligibleVoters',eligible,'entries',coalesce(items,'[]'::jsonb),'myPlayerId',p.id,'mySubmitted',submitted,'myVoted',voted,'isHost',h,'winnerIds',win_ids,'finaleWinnerIds',finale_wins,'historyRemaining',remaining,'paused',r.paused);
end $$;
-- Realtime signals use public channels only, with NO private game payload in broadcasts.
-- The HTTP API remains the authority for all state and action validation.
-- Manual cleanup (Supabase SQL editor or scheduled pg_cron if available):
-- delete from public.rooms where expires_at < now();
-- delete from public.anonymous_hosts h where not exists(select 1 from public.rooms r where r.host_id=h.id) and h.created_at < now()-interval '180 days';
-- Enforce exact proportional tie bonuses (e.g. three winners get 66⅔ each).
alter table public.room_players alter column score type numeric(12,6);
create or replace function public.td_award_score(p_v int,p_max int,p_winners int) returns numeric language sql immutable as $$ select p_v*100::numeric + case when p_max>0 and p_v=p_max then 200::numeric/p_winners else 0 end $$;
-- Restrict SECURITY DEFINER RPC entrypoints to the server's service-role key.
revoke all on function public.td_eligible(text,text,text) from public,anon,authenticated;
revoke all on function public.td_assign_movie(uuid) from public,anon,authenticated;
revoke all on function public.td_finalists(uuid) from public,anon,authenticated;
revoke all on function public.td_progress(uuid,boolean) from public,anon,authenticated;
revoke all on function public.td_action(text,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.td_join(text,text,text) from public,anon,authenticated;
revoke all on function public.td_view(text,text) from public,anon,authenticated;
revoke all on function public.td_award_score(int,int,int) from public,anon,authenticated;
grant execute on function public.td_action(text,text,text,jsonb) to service_role;
grant execute on function public.td_join(text,text,text) to service_role;
grant execute on function public.td_view(text,text) to service_role;
