-- =====================================================================
-- USER database (ppcxuptjzhrqkcdokryk) — run once in its SQL Editor.
-- Adds the "last shared with admin" date. Safe to run more than once.
-- =====================================================================
alter table public.motor_proposals add column if not exists shared_at   timestamptz;
alter table public.motor_proposals add column if not exists shared_from text;
notify pgrst, 'reload schema';
select count(*) as quotations from public.motor_proposals;
