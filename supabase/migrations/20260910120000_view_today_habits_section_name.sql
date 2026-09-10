-- =============================================================================
-- supabase/migrations/20260910120000_view_today_habits_section_name.sql
--
-- Expone section_name (nombre de habit_sections) en v_today_habits, resuelto
-- via join, para que un cliente pueda filtrar/agrupar habitos por seccion sin
-- tener que resolver el UUID crudo de section_id por su cuenta (p.ej. una
-- vista nueva del deck que muestre solo los habitos de una seccion dada por
-- nombre).
--
-- No se toca v_log_habits: fuera de alcance de este cambio.
-- =============================================================================

create or replace view v_today_habits as
with wk as (
    select date_trunc('week', app_today())::date as week_start  -- lunes ISO
),
base as (
    select h.id, h.name, h.icon_res, h.color, h.type, h.goal, h.step, h.unit,
           h.manual_entry, h.sort_order, h.section_id,
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
-- section_name va al FINAL de la lista de columnas a proposito: Postgres no
-- admite insertar una columna nueva en medio de una vista via
-- `create or replace view` (lo trata como un rename de la columna que ocupaba
-- esa posicion y falla con "cannot change name of view column"). Columnas
-- calificadas con `b.`/`s.` porque el join introduce `id`/`name` duplicados
-- (habito vs seccion).
select b.id, b.name, b.icon_res, b.color, b.type, b.goal, b.step, b.unit, b.sort_order, b.section_id,
       b.current_value,
       b.current_value >= b.goal as done,
       app_today()               as day,
       b.manual_entry,
       s.name                    as section_name
  from base b
  left join habit_sections s on s.id = b.section_id
 where b.is_due;

comment on view v_today_habits is
    'Habitos con objetivo que tocan hoy segun su schedule_type, con el progreso de hoy '
    '(o de la semana, en weekly_quota). No arrastran deuda. section_name resuelve el '
    'nombre de habit_sections (NULL si el habito no tiene section_id).';
