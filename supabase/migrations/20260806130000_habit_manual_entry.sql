-- =============================================================================
-- 20260806130000_habit_manual_entry.sql
--
-- Nuevo eje independiente para habits: manual_entry. Si es true, el cliente
-- (Stream Deck) debe pedir un valor exacto y fijarlo con habit_set en vez de
-- sumar step con habit_step (p.ej. un habito "Peso"). Solo tiene sentido con
-- type = 'Real'; habit_set ya existe y ya tiene su grant a anon, asi que no
-- hace falta tocar ninguna funcion ni rls_contract.sql.
--
-- create or replace view conserva los grants ya existentes (comprobado en
-- CLAUDE.md), asi que reescribir v_today_habits aqui no requiere volver a
-- otorgar select sobre ella.
-- =============================================================================

alter table habits add column manual_entry boolean not null default false;

alter table habits add constraint habits_manual_entry_real_chk
    check (not manual_entry or type = 'Real');

comment on column habits.manual_entry is
    'true = la tecla del deck abre un teclado numerico para fijar el valor '
    'exacto del dia (via habit_set) en vez de sumar step (habit_step). '
    'Solo tiene sentido si type=''Real''.';

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
select id, name, icon_res, color, type, goal, step, unit, sort_order, section_id,
       current_value,
       current_value >= goal as done,
       app_today()           as day,
       manual_entry
  from base
 where is_due;

comment on view v_today_habits is
    'Habitos con objetivo que tocan hoy segun su schedule_type, con el progreso de hoy '
    '(o de la semana, en weekly_quota). No arrastran deuda.';
