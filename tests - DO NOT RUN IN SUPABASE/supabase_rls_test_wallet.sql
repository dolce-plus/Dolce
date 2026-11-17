-- LOCAL TEST ONLY (throwaway Postgres with stubs). NEVER run in Supabase.
\set ON_ERROR_STOP 0
create or replace function pg_temp.ok(c boolean, label text) returns void language plpgsql as $$ begin raise notice '% %', case when c then 'PASS' else 'FAIL' end, label; end $$;
insert into public.clients(id,name,points,phone) values ('11111111-1111-4111-8111-111111111111','Dana Karim',0,'9647500000009');
-- 1 issue card
select pg_temp.ok((select count(*) from public.wallet_cards)=0,'no card before');
select pg_temp.ok((select member_code ~ '^DP[2-9A-HJ-NP-Z]{10}$' from public.wallet_issue_card('11111111-1111-4111-8111-111111111111')),'card issued, code format');
select pg_temp.ok((select serial from public.wallet_issue_card('11111111-1111-4111-8111-111111111111'))=(select serial from public.wallet_cards),'issue again = same card');
select pg_temp.ok((select name='Dana Karim' and points=0 and tier='member' and member_since=current_date from public.wallet_cards),'card shows name/points/member');
-- 2 no notify without registrations
insert into public.point_transactions(client_id,kind,points,spend) values ('11111111-1111-4111-8111-111111111111','earn',100,100);
select pg_temp.ok((select points from public.wallet_cards)=100,'points follow ledger');
select pg_temp.ok((select count(*) from net.calls)=0,'no push when no iPhone holds it');
insert into public.wallet_registrations values ('dev1','pass.x',(select serial from public.wallet_cards),'abcd');
-- 3 points change → push
update public.wallet_cards set updated_at=now()-interval '1 hour';
insert into public.point_transactions(client_id,kind,points,spend) values ('11111111-1111-4111-8111-111111111111','earn',950,950);
select pg_temp.ok((select points=1050 and tier='gold' from public.wallet_cards),'gold at 1050 spend');
select pg_temp.ok((select count(*) from net.calls)>=1 and (select body->>'serial' from net.calls order by id desc limit 1)=(select serial from public.wallet_cards),'push requested with serial');
select pg_temp.ok((select updated_at > now()-interval '1 minute' from public.wallet_cards),'updated_at bumped');
-- 4 redeem keeps level
insert into public.point_transactions(client_id,kind,points,spend) values ('11111111-1111-4111-8111-111111111111','redeem',-500,0);
select pg_temp.ok((select points=550 and tier='gold' from public.wallet_cards),'redeem lowers points not level');
-- 5 settings as JSON string
insert into public.settings values ('loyalty', to_jsonb('{"gold":2000,"black":5000}'::text));
select public.wallet_refresh_all();
select pg_temp.ok((select tier from public.wallet_cards)='member','settings string parsed (gold 2000)');
update public.settings set value='{"gold":500,"black":1000}'::jsonb where key='loyalty';
select public.wallet_refresh_all();
select pg_temp.ok((select tier from public.wallet_cards)='black','settings object parsed');
update public.settings set value='"garbage"'::jsonb where key='loyalty';
select public.wallet_refresh_all();
select pg_temp.ok((select tier from public.wallet_cards)='gold','bad settings → defaults');
-- 6 old spend expires
update public.point_transactions set created_at=now()-interval '400 days';
select public.wallet_refresh_all();
select pg_temp.ok((select tier from public.wallet_cards)='member','level drops after 12 months');
-- 7 refund reverse
insert into public.point_transactions(client_id,kind,points,spend) values ('11111111-1111-4111-8111-111111111111','earn',1200,1200);
insert into public.point_transactions(client_id,kind,points,spend) values ('11111111-1111-4111-8111-111111111111','reverse',-300,-300);
select pg_temp.ok((select tier from public.wallet_cards)='member','refund lowers level spend (900)');
-- 8 name change
select count(*) as c0 from net.calls \gset
update public.clients set name='Dana K.' where id='11111111-1111-4111-8111-111111111111';
select pg_temp.ok((select name from public.wallet_cards)='Dana K.' and (select count(*) from net.calls)=:c0+1,'name change refreshes + pushes');
update public.clients set phone='9647500000008' where id='11111111-1111-4111-8111-111111111111';
select pg_temp.ok((select count(*) from net.calls)=:c0+1,'unrelated change → no push');
-- 9 net failure never blocks
alter function net.http_post(text,jsonb,jsonb) rename to http_post_x;
insert into public.point_transactions(client_id,kind,points,spend) values ('11111111-1111-4111-8111-111111111111','bonus',10,0);
select pg_temp.ok((select points from public.clients where id='11111111-1111-4111-8111-111111111111')=(select points from public.wallet_cards),'push link broken → points still saved');
alter function net.http_post_x(text,jsonb,jsonb) rename to http_post;
-- 10 permissions
set role anon;
select pg_temp.ok(false,'anon read cards SHOULD FAIL') from public.wallet_cards limit 1;
reset role; set role authenticated;
select pg_temp.ok(false,'auth read regs SHOULD FAIL') from public.wallet_registrations limit 1;
select public.wallet_issue_card('11111111-1111-4111-8111-111111111111');
select public.wallet_refresh_all();
-- lookup
select set_config('t.staff','0',false);
select public.wallet_member_lookup('x');
select set_config('t.staff','1',false), set_config('t.tabs','products',false);
select public.wallet_member_lookup('x');
reset role;
select member_code as code from public.wallet_cards \gset
set role authenticated;
select set_config('t.tabs','loyalty',false), set_config('t.see','1',false);
select pg_temp.ok((select name='Dana K.' and visible from public.wallet_member_lookup(lower(substr(:'code',1,2)||'-'||substr(:'code',3,5)||' '||substr(:'code',8)))),'staff lookup (dashes/lowercase ok)');
select set_config('t.see','0',false);
select pg_temp.ok((select not visible from public.wallet_member_lookup(:'code')),'lookup flags not-visible client');
select pg_temp.ok((select count(*) from public.wallet_member_lookup('DPAAAAAAAAAA'))=0,'unknown code → nothing');
reset role;
-- 11 delete client deletes card + registrations
delete from public.clients where id='11111111-1111-4111-8111-111111111111';
select pg_temp.ok((select count(*) from public.wallet_cards)=0 and (select count(*) from public.wallet_registrations)=0,'client deleted → card + registrations removed');
select pg_temp.ok((select count(*) from public.point_transactions)>0,'ledger untouched');
-- 12 unknown client
select public.wallet_issue_card('99999999-1111-4111-8111-111111111111');
