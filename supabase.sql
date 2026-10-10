-- =====================================================================
-- VAULT CUENTAS · Ejecutar completo en Supabase > SQL Editor > Run
-- =====================================================================

create extension if not exists pgcrypto;

-- 1) Tabla -------------------------------------------------------------
create table if not exists public.accounts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  email       text not null,
  password    text not null,
  project     text not null default '',
  status      text not null default 'disponible'
              check (status in ('disponible','en_uso','utilizado')),
  used_at     timestamptz,                       -- hora exacta (servidor) en que pasó a EN USO
  created_at  timestamptz not null default now()
);

create index if not exists accounts_user_idx on public.accounts(user_id, created_at);

-- 2) Seguridad (RLS): cada fila solo es visible para su dueño ------------
alter table public.accounts enable row level security;

drop policy if exists "accounts_owner_all" on public.accounts;
create policy "accounts_owner_all" on public.accounts
  for all to authenticated
  using      (user_id = auth.uid())
  with check (user_id = auth.uid());

-- 3) Hora del servidor (evita depender del reloj del navegador/celular) ---
create or replace function public.server_time()
returns timestamptz language sql stable as $$ select now() $$;

-- 4) Copiar => EN USO + timestamp del servidor (solo si estaba DISPONIBLE).
--    Si ya estaba EN USO no reinicia el contador de 30 min.
create or replace function public.mark_in_use(p_id uuid)
returns public.accounts language plpgsql as $$
declare r public.accounts;
begin
  update public.accounts
     set status = 'en_uso', used_at = now()
   where id = p_id and status = 'disponible'
  returning * into r;

  if r.id is null then
    select * into r from public.accounts where id = p_id;
  end if;
  return r;
end $$;

-- 5) A los 30 min exactos: EN USO => UTILIZADO (queda registrado en la BD) -
create or replace function public.expire_accounts()
returns int language plpgsql as $$
declare n int;
begin
  update public.accounts
     set status = 'utilizado'
   where status = 'en_uso'
     and used_at <= now() - interval '30 minutes';
  get diagnostics n = row_count;
  return n;
end $$;

-- 6) Reset individual (pasa id) o general (sin parámetro) ------------------
create or replace function public.reset_accounts(p_id uuid default null)
returns int language plpgsql as $$
declare n int;
begin
  update public.accounts
     set status = 'disponible', used_at = null
   where status <> 'disponible'
     and (p_id is null or id = p_id);
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function public.server_time()          to authenticated;
grant execute on function public.mark_in_use(uuid)      to authenticated;
grant execute on function public.expire_accounts()      to authenticated;
grant execute on function public.reset_accounts(uuid)   to authenticated;

-- 7) Tiempo real (sincroniza PC y celular al instante) ---------------------
alter publication supabase_realtime add table public.accounts;

-- 8) OPCIONAL: que la BD expire cuentas aunque no abras la app.
--    Activa antes la extensión en Database > Extensions > pg_cron
-- select cron.schedule('expire-accounts', '* * * * *', $$ select public.expire_accounts(); $$);
