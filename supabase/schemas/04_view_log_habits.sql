-- =============================================================================
-- supabase/schemas/04_view_log_habits.sql
--
-- Definicion del ESTADO ACTUAL (no historia). Espejo de
-- supabase/migrations/20260724120100_view_log_habits.sql.
--
-- Contrato de LECTURA: los habitos de solo registro (purpose = 'log').
--
-- No tienen objetivo ni programacion: nunca salen en v_today_habits, porque no
-- son "pendientes". Existen para poder pulsar un check ("bebi cocacola hoy") y
-- consultarlos luego.
--
-- Por eso la vista no expone `goal`, `step` ni `done`: no significan nada aqui.
--
-- Si cambias algo aqui, cambia tambien la migration correspondiente en el
-- mismo commit -- no hay generacion automatica (no hay Supabase CLI instalado).
-- =============================================================================
create or replace view v_log_habits as
select h.id, h.name, h.icon_res, h.color, h.type, h.unit, h.sort_order, h.section_id,
       coalesce((select c.value
                   from habit_checkins c
                  where c.habit_id = h.id
                    and c.checkin_date = app_today()), 0) as current_value,
       app_today() as day
  from habits h
 where h.status = 0
   and h.purpose = 'log';

comment on view v_log_habits is
    'Habitos de solo registro (purpose=log). Nunca son pendientes; se pulsan para dejar rastro.';
