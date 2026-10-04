-- =====================================================================
-- TSI Wealth Planners — Motor Takaful Value Proposal module
-- Run once in the Supabase SQL editor. Safe to re-run.
-- Standalone, NO LOGIN: the dashboard and the client link both use the
-- publishable (anon) key. WARNING: anyone holding that key can read and
-- change every proposal and payment slip.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Global, atomic reference numbering (MTVP-2026-00001) ----------
create sequence if not exists public.motor_proposal_ref_seq;

create table if not exists public.motor_proposals (
  id                 uuid primary key default gen_random_uuid(),
  reference_no       text unique not null default (
                        'MTVP-' || to_char(now() at time zone 'Asia/Kuala_Lumpur', 'YYYY') || '-' ||
                        lpad(nextval('public.motor_proposal_ref_seq')::text, 5, '0')),
  public_token       uuid unique not null default gen_random_uuid(),
  created_by         uuid default auth.uid(),

  -- IFAR
  ifar_name          text not null,
  ifar_phone         text not null,

  -- Prospect / vehicle
  owner_name         text not null,
  owner_id_no        text not null,
  vehicle_reg_no     text not null,
  vehicle_type       text not null check (vehicle_type in ('Sedan','SUV','MPV','Motorcycle')),
  vehicle_model      text not null,
  engine_capacity    text,
  usage_type         text not null check (usage_type in ('Personal','Company')),
  vehicle_address    text,
  prospect_email     text,
  prospect_phone     text,
  ncd                text,
  coverage_term      text,

  -- Proposal: [{operator, sum_covered, road_tax, admin_fee, note,
  --             options:[{code, name, takaful_price, road_tax, admin_fee}]}]
  quotes             jsonb not null default '[]'::jsonb,

  -- Filled when IFAR / client sends to Sales Dept
  selected_quote     jsonb,
  payment_amount     numeric(12,2),
  payment_reference  text,
  payment_slip_path  text,
  payment_slip_name  text,
  pdf_path           text,

  status             text not null default 'OPEN' check (status in ('OPEN','SUBMITTED','CLOSED')),
  audit_log          jsonb not null default '[]'::jsonb,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  submitted_at       timestamptz,
  closed_at          timestamptz
);

-- If an earlier version of this script was run, relax created_by
alter table public.motor_proposals alter column created_by drop not null;
alter table public.motor_proposals drop constraint if exists motor_proposals_created_by_fkey;

create index if not exists motor_proposals_created_by_idx on public.motor_proposals (created_by);
create index if not exists motor_proposals_status_idx on public.motor_proposals (status);

-- ---------- Row level security: open to the public (anon) role ----------
alter table public.motor_proposals enable row level security;

drop policy if exists motor_proposals_select on public.motor_proposals;
create policy motor_proposals_select on public.motor_proposals
  for select to anon, authenticated
  using (true);

drop policy if exists motor_proposals_insert on public.motor_proposals;
create policy motor_proposals_insert on public.motor_proposals
  for insert to anon, authenticated
  with check (true);

drop policy if exists motor_proposals_update on public.motor_proposals;
create policy motor_proposals_update on public.motor_proposals
  for update to anon, authenticated
  using (true)
  with check (true);

-- Only OPEN cases can be deleted
drop policy if exists motor_proposals_delete on public.motor_proposals;
create policy motor_proposals_delete on public.motor_proposals
  for delete to anon, authenticated
  using (status = 'OPEN');

-- ---------- Public link: read by token ----------
drop function if exists public.get_motor_proposal_by_token(uuid);
create or replace function public.get_motor_proposal_by_token(p_token uuid)
returns table (
  reference_no text, ifar_name text, ifar_phone text,
  owner_name text, owner_id_no text, vehicle_reg_no text, vehicle_type text,
  vehicle_model text, engine_capacity text, usage_type text, vehicle_address text,
  prospect_email text, prospect_phone text, ncd text, coverage_term text,
  quotes jsonb, selected_quote jsonb, payment_amount numeric, payment_reference text,
  payment_slip_name text, status text, created_at timestamptz, submitted_at timestamptz
)
language sql stable security definer set search_path = public
as $$
  select m.reference_no, m.ifar_name, m.ifar_phone,
         m.owner_name, m.owner_id_no, m.vehicle_reg_no, m.vehicle_type,
         m.vehicle_model, m.engine_capacity, m.usage_type, m.vehicle_address,
         m.prospect_email, m.prospect_phone, m.ncd, m.coverage_term,
         m.quotes, m.selected_quote, m.payment_amount, m.payment_reference,
         m.payment_slip_name, m.status, m.created_at, m.submitted_at
  from public.motor_proposals m
  where m.public_token = p_token;
$$;
grant execute on function public.get_motor_proposal_by_token(uuid) to anon, authenticated;

-- ---------- Public link: submit selection + payment to Sales Dept ----------
-- Prices are taken from the stored proposal, never from the browser.
drop function if exists public.submit_motor_proposal(uuid, text, text, numeric, text, text, text, text);
create or replace function public.submit_motor_proposal(
  p_token uuid, p_operator text, p_option_code text,
  p_payment_amount numeric, p_payment_reference text,
  p_slip_path text, p_slip_name text, p_pdf_path text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_row   public.motor_proposals;
  v_quote jsonb;
  v_opt   jsonb;
  v_sel   jsonb;
  v_tp numeric; v_rt numeric; v_af numeric;
begin
  select * into v_row from public.motor_proposals where public_token = p_token for update;
  if not found then raise exception 'Proposal not found.'; end if;
  if v_row.status <> 'OPEN' then return null; end if;

  select q into v_quote from jsonb_array_elements(v_row.quotes) q where q->>'operator' = p_operator limit 1;
  if v_quote is null then raise exception 'Selected Takaful operator is not part of this proposal.'; end if;

  select o into v_opt from jsonb_array_elements(v_quote->'options') o where o->>'code' = p_option_code limit 1;
  if v_opt is null then raise exception 'Selected option is not part of this proposal.'; end if;

  if coalesce(p_payment_amount, 0) <= 0 then raise exception 'Payment amount is required.'; end if;
  if coalesce(trim(p_payment_reference), '') = '' then raise exception 'Payment reference number is required.'; end if;
  if p_slip_path is null or split_part(p_slip_path, '/', 1) <> p_token::text then raise exception 'Payment slip is required.'; end if;
  if p_pdf_path  is null or split_part(p_pdf_path,  '/', 1) <> p_token::text then raise exception 'Proposal PDF is missing.'; end if;

  v_tp := coalesce((v_opt->>'takaful_price')::numeric, 0);
  v_rt := coalesce((v_opt->>'road_tax')::numeric, (v_quote->>'road_tax')::numeric, 0);
  v_af := coalesce((v_opt->>'admin_fee')::numeric, (v_quote->>'admin_fee')::numeric, 20);

  v_sel := jsonb_build_object(
    'operator', p_operator,
    'sum_covered', v_quote->'sum_covered',
    'note', v_quote->'note',
    'option_code', p_option_code,
    'option_name', v_opt->>'name',
    'takaful_price', v_tp, 'road_tax', v_rt, 'admin_fee', v_af,
    'total', v_tp + v_rt + v_af);

  update public.motor_proposals set
    selected_quote    = v_sel,
    payment_amount    = round(p_payment_amount, 2),
    payment_reference = trim(p_payment_reference),
    payment_slip_path = p_slip_path,
    payment_slip_name = p_slip_name,
    pdf_path          = p_pdf_path,
    status            = 'SUBMITTED',
    submitted_at      = now(),
    updated_at        = now(),
    audit_log         = audit_log || jsonb_build_array(jsonb_build_object(
                          'action', 'Option selected & payment sent to Sales Dept',
                          'timestamp', now()))
  where id = v_row.id;

  return v_sel;
end;
$$;
grant execute on function public.submit_motor_proposal(uuid, text, text, numeric, text, text, text, text) to anon, authenticated;

-- ---------- Storage: payment slips + generated PDFs ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('motor-proposals', 'motor-proposals', false, 10485760,
        array['application/pdf','image/png','image/jpeg','image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.motor_token_is_open(p_token text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.motor_proposals
                 where public_token::text = p_token and status = 'OPEN');
$$;
grant execute on function public.motor_token_is_open(text) to anon, authenticated;

-- Link holders can upload only into the folder of an OPEN proposal: <token>/<file>
drop policy if exists "motor proposal uploads by open token" on storage.objects;
create policy "motor proposal uploads by open token" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'motor-proposals'
              and public.motor_token_is_open((storage.foldername(name))[1]));

-- Dashboard (no login) can open uploaded slips and generated PDFs
drop policy if exists "motor proposal files readable by owner" on storage.objects;
drop policy if exists "motor proposal files readable" on storage.objects;
create policy "motor proposal files readable" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'motor-proposals');

-- ---------- Table privileges for the anon role ----------
grant usage on schema public to anon;
grant select, insert, update, delete on public.motor_proposals to anon;
grant usage, select on sequence public.motor_proposal_ref_seq to anon;
