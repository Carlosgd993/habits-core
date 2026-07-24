-- =============================================================================
-- 20260724120000_time_and_status
--
-- Dos cimientos que todo lo demas asume:
--   1. Un unico dueno de la nocion de "hoy".
--   2. Una forma de saber que fila de `statuses` significa "hecho", sin
--      hardcodear un UUID en ningun cliente.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app_today() -- la unica fuente de verdad sobre que dia es hoy
--
-- El servidor de Supabase corre en UTC: `current_date` cambia de dia a las 02:00
-- de Madrid en verano. Un checkin hecho a la 01:30 caeria en "ayer".
--
-- Regla del ecosistema: NINGUN cliente envia nunca una fecha. La calcula esto.
-- Si algun dia cambias de huso, cambias esta funcion y se entera todo a la vez.
-- -----------------------------------------------------------------------------
create or replace function app_timezone() returns text
    language sql immutable
as $$
select 'Europe/Madrid'::text;
$$;

create or replace function app_today() returns date
    language sql stable
as $$
select (now() at time zone app_timezone())::date;
$$;

comment on function app_today() is
    'El "hoy" del ecosistema, en la zona de app_timezone(). Unico dueno de la fecha.';

-- -----------------------------------------------------------------------------
-- statuses.is_done -- marca cual de los estados del catalogo cierra una tarea
--
-- `statuses` es un catalogo libre (Por hacer / En progreso / Hecho / ...). Sin
-- esta columna, `complete_task()` tendria que conocer un UUID concreto, y ese
-- UUID acabaria copiado en el .env de la Pi, en la PWA y en el bot.
--
-- El indice parcial unico garantiza que solo haya un estado "hecho".
-- -----------------------------------------------------------------------------
alter table statuses
    add column if not exists is_done boolean not null default false;

create unique index if not exists statuses_single_done_idx
    on statuses (is_done) where is_done;

comment on column statuses.is_done is
    'true en el (unico) estado que representa "tarea completada".';

-- Semilla minima: si no hay ningun estado marcado, se crea "Hecho".
insert into statuses (name, sort_order, is_done)
select 'Hecho', 100, true
where not exists (select 1 from statuses where is_done);
