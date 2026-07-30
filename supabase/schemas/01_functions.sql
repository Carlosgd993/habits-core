-- =============================================================================
-- supabase/schemas/01_functions.sql
--
-- Definicion del ESTADO ACTUAL (no historia). Espejo de la seccion 1 de
-- supabase/migrations/20260724115900_init.sql. No se despliega directamente:
-- es para lectura y para reconstruir la base desde cero (ver CLAUDE.md).
--
-- Si cambias algo aqui, cambia tambien la migration correspondiente en el
-- mismo commit -- no hay generacion automatica (no hay Supabase CLI instalado).
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
-- Estas dos van A PROPOSITO sin `set search_path`, al contrario que el resto
-- del repo. `supabase db advisors` las marcara con `function_search_path_mutable`
-- y es un falso positivo asumido:
--
--   - Son `security invoker`, no `definer`: se ejecutan con los permisos de
--     quien llama, asi que un search_path secuestrado no escala privilegios.
--     Ademas `anon` solo tiene USAGE sobre `public`, nunca CREATE, asi que no
--     puede plantar una funcion suya que suplante a `app_timezone()`.
--   - Una funcion con clausula `SET` deja de ser inlineable por el planner, y
--     `app_today()` aparece seis veces en el predicado de `v_today_habits`.
--     Perder el inlining ahi no compensa silenciar un aviso que no describe
--     ningun riesgo real.
--
-- La regla "toda `security definer` lleva `set search_path`" sigue en pie sin
-- excepciones: es justo lo que estas dos no son.
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
-- set_updated_at() -- alimenta el trigger de updated_at de todas las tablas
--
-- Esta SI lleva `set search_path`: es plpgsql (no hay inlining que perder) y se
-- ejecuta dentro de un trigger, con el search_path de quien haga el UPDATE.
-- -----------------------------------------------------------------------------
create or replace function set_updated_at()
    returns trigger language plpgsql
    set search_path = public
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;
