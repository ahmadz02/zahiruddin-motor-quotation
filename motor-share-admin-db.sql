-- =====================================================================
-- ADMIN database (olgijssakwgttfnomnwz) — run once in its SQL Editor.
-- Prepares it to receive "Share with Admin" quotations from the user portal
-- and to run the admin portal. Safe to run more than once. Deletes nothing.
-- =====================================================================

-- A) Bring the table up to the current quotation layout
-- 1) New columns (each quotation stays its own unique row)
alter table public.motor_proposals add column if not exists quotation_date timestamptz;
alter table public.motor_proposals add column if not exists responded_at   timestamptz;
alter table public.motor_proposals add column if not exists coverage_start date;
alter table public.motor_proposals add column if not exists coverage_end   date;
alter table public.motor_proposals add column if not exists renewed_from   uuid;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'motor_proposals_renewed_from_fkey') then
    alter table public.motor_proposals
      add constraint motor_proposals_renewed_from_fkey foreign key (renewed_from)
      references public.motor_proposals(id) on delete set null;
  end if;
end $$;

-- 2) Statuses: remove the old check, convert old values, add the new check
do $$
declare r record;
begin
  for r in select conname from pg_constraint
           where conrelid = 'public.motor_proposals'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) ilike '%status%' loop
    execute format('alter table public.motor_proposals drop constraint %I', r.conname);
  end loop;
end $$;

update public.motor_proposals set status = 'QUOTED' where status = 'OPEN';
update public.motor_proposals
   set status = 'ACCEPTED', responded_at = coalesce(responded_at, closed_at, submitted_at, updated_at)
 where status in ('SUBMITTED', 'CLOSED');

alter table public.motor_proposals alter column status set default 'QUOTED';
alter table public.motor_proposals
  add constraint motor_proposals_status_check check (status in ('QUOTED', 'ACCEPTED', 'DECLINED'));

-- 3) Fill the new dates for existing quotations
update public.motor_proposals set quotation_date = coalesce(updated_at, created_at) where quotation_date is null;

update public.motor_proposals
   set coverage_start = to_date(substring(coverage_term from '^\s*(\d{1,2}/\d{1,2}/\d{4})'), 'DD/MM/YYYY')
 where coverage_start is null and coverage_term ~ '^\s*\d{1,2}/\d{1,2}/\d{4}';
update public.motor_proposals
   set coverage_end = to_date(substring(coverage_term from '(\d{1,2}/\d{1,2}/\d{4})\s*$'), 'DD/MM/YYYY')
 where coverage_end is null and coverage_term ~ '\d{1,2}/\d{1,2}/\d{4}\s*$'
   and coverage_term ~ '\d{1,2}/\d{1,2}/\d{4}.*\d{1,2}/\d{1,2}/\d{4}';

create index if not exists motor_proposals_renewed_from_idx on public.motor_proposals (renewed_from);
create index if not exists motor_proposals_coverage_end_idx on public.motor_proposals (coverage_end);

-- 4) Delete is only allowed while a quotation is awaiting response
drop policy if exists motor_proposals_delete on public.motor_proposals;
create policy motor_proposals_delete on public.motor_proposals
  for delete to anon, authenticated using (status = 'QUOTED');

-- 5) Refresh the Supabase API
notify pgrst, 'reload schema';


-- B) Columns for shared quotations
alter table public.motor_proposals add column if not exists shared_at   timestamptz;
alter table public.motor_proposals add column if not exists shared_from text;

-- C) Shared quotations keep the user portal's reference number, which may also
--    exist here. Each quotation is still unique by its ID.
alter table public.motor_proposals drop constraint if exists motor_proposals_reference_no_key;
create index if not exists motor_proposals_reference_no_idx on public.motor_proposals (reference_no);

-- D) Open (no-login) access, needed for sharing and for the admin portal
alter table public.motor_proposals enable row level security;
drop policy if exists motor_proposals_select on public.motor_proposals;
create policy motor_proposals_select on public.motor_proposals for select to anon, authenticated using (true);
drop policy if exists motor_proposals_insert on public.motor_proposals;
create policy motor_proposals_insert on public.motor_proposals for insert to anon, authenticated with check (true);
drop policy if exists motor_proposals_update on public.motor_proposals;
create policy motor_proposals_update on public.motor_proposals for update to anon, authenticated using (true) with check (true);
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.motor_proposals to anon, authenticated;
grant usage, select on sequence public.motor_proposal_ref_seq to anon, authenticated;

notify pgrst, 'reload schema';

-- Check
select count(*) filter (where shared_from is not null) as shared_by_user,
       count(*) as all_quotations
from public.motor_proposals;
