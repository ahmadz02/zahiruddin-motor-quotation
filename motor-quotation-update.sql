-- =====================================================================
-- Motor Takaful Quotation: database UPDATE (run once on your existing database)
-- Adds quotation date, response date, coverage dates and renewal link.
-- Changes statuses to QUOTED / ACCEPTED / DECLINED. Safe to run more than once.
-- Does NOT delete any quotation.
-- =====================================================================

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

-- 6) Check: counts per status
select status, count(*) from public.motor_proposals group by status order by status;
