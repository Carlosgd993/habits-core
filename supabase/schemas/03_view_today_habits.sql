-- =============================================================================
-- supabase/schemas/03_view_today_habits.sql
--
-- Definicion del ESTADO ACTUAL (no historia). Espejo de
-- supabase/migrations/20260724120000_view_today_habits.sql.
--
-- Contrato de LECTURA: los habitos con objetivo que TOCAN hoy.
--
-- REGLA DE COMPATIBILIDAD: a una vista se le ANADEN columnas. Nunca se le
-- quitan ni se renombran. Quitar una columna rompe la Pi en silencio.
--
-- La vista NO lleva `security_invoker`: se ejecuta con los permisos de su
-- propietario y por tanto atraviesa el RLS de las tablas. Los clientes leen la
-- vista, nunca la tabla.
--
-- Si cambias algo aqui, cambia tambien la migration correspondiente en el
-- mismo commit -- no hay generacion automatica (no hay Supabase CLI instalado).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Un habito SIEMPRE es de hoy: no arrastra deuda ni vence. Si ayer se quedo en
-- 2/8, hoy vuelve a empezar en 0/8.
--
-- "Toca hoy" depende del schedule_type:
--   interval_calendar : (hoy - anchor) es multiplo de interval_n
--   weekly_days       : hoy (isodow) esta en byday
--   weekly_quota      : SIEMPRE se muestra (cualquier dia cuenta)
--   monthly_day       : dia del mes = bymonthday
--
-- current_value tambien depende del tipo:
--   weekly_quota : nº de dias con checkin en la semana ISO actual (2/3)
--   resto        : valor del checkin de hoy (puede superar goal: 10/8 valido)
--
-- `done` solo indica si se ha alcanzado el objetivo, no si se puede seguir
-- sumando.
-- -----------------------------------------------------------------------------
create or replace view v_today_habits as
with wk as (
    select date_trunc('week', app_today())::date as week_start  -- lunes ISO
),
base as (
    select h.id, h.name, h.icon_res, h.color, h.type, h.goal, h.step, h.unit,
           h.sort_order, h.section_id,
           case
               when h.schedule_type = 'weekly_quota'
                   then (select count(*)::double precision
                           from habit_checkins c, wk
                          where c.habit_id = h.id
                            and c.checkin_date >= wk.week_start
                            and c.checkin_date <  wk.week_start + 7
                            and c.value > 0)
               else coalesce((select c.value
                                from habit_checkins c
                               where c.habit_id = h.id
                                 and c.checkin_date = app_today()), 0)
           end as current_value,
           case h.schedule_type
               when 'interval_calendar'
                   -- `app_today() >= anchor_date` no es decorativo: sin el, un
                   -- ancla en el FUTURO ya empezaria a tocar hoy. La resta seria
                   -- negativa y el `%` de Postgres devuelve resto negativo
                   -- (-6 % 3 = 0), asi que un habito programado para empezar
                   -- dentro de 6 dias apareceria hoy. El ancla es el ARRANQUE de
                   -- la serie, no solo su punto de referencia.
                   then h.anchor_date is not null
                        and app_today() >= h.anchor_date
                        and ((app_today() - h.anchor_date) % h.interval_n) = 0
               when 'weekly_days'
                   then extract(isodow from app_today())::smallint = any (h.byday)
               when 'weekly_quota'
                   then true
               when 'monthly_day'
                   then extract(day from app_today())::smallint = h.bymonthday
               else false
           end as is_due
      from habits h
     where h.status = 0
       and h.purpose = 'goal'
)
select id, name, icon_res, color, type, goal, step, unit, sort_order, section_id,
       current_value,
       current_value >= goal as done,
       app_today()           as day
  from base
 where is_due;

comment on view v_today_habits is
    'Habitos con objetivo que tocan hoy segun su schedule_type, con el progreso de hoy '
    '(o de la semana, en weekly_quota). No arrastran deuda.';
