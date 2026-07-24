-- =============================================================================
-- 20260724120100_views_today
--
-- El contrato de LECTURA. Los clientes consultan estas vistas, nunca las tablas.
-- El cuerpo de la vista puede reescribirse entero (recurrencias, plantillas...)
-- sin que ningun cliente se entere, mientras las columnas se mantengan.
--
-- REGLA DE COMPATIBILIDAD: a una vista se le ANADEN columnas. Nunca se le
-- quitan ni se renombran. Quitar una columna rompe la Pi en silencio.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- v_today_habits -- los habitos de hoy
--
-- Un habito SIEMPRE es de hoy: no arrastra deuda ni vence. Si ayer se quedo en
-- 2/8, hoy vuelve a empezar en 0/8. Por eso no hay filtro de fecha ni de
-- recurrencia aqui: se listan todos los habitos activos.
--
-- `current_value` puede superar a `goal` (10/8 es un estado valido). `done` solo
-- indica si se ha alcanzado el objetivo, no si se puede seguir sumando.
-- -----------------------------------------------------------------------------
create or replace view v_today_habits as
select h.id,
       h.name,
       h.icon_res,
       h.color,
       h.type,
       h.goal,
       h.step,
       h.unit,
       h.sort_order,
       h.section_id,
       coalesce(c.value, 0)                as current_value,
       coalesce(c.value, 0) >= h.goal      as done,
       app_today()                         as day
from habits h
         left join habit_checkins c
                   on c.habit_id = h.id
                       and c.checkin_date = app_today()
where h.status = 0;

comment on view v_today_habits is
    'Habitos activos con su progreso de hoy. Los habitos no vencen ni acumulan atraso.';

-- -----------------------------------------------------------------------------
-- v_today_tasks -- las tareas de hoy
--
-- A diferencia de los habitos, una tarea SI arrastra: si vencia el lunes y no se
-- hizo, sigue apareciendo el jueves (`due_day <= hoy`), marcada con `overdue`.
--
-- Se excluyen las tareas SIN fecha: con 12 teclas utiles en la Stream Deck, el
-- inbox entero inundaria la pantalla. Cuando haga falta, iran en una vista
-- aparte (`v_inbox_tasks`), no aqui.
--
-- Cuando existan plantillas y ocurrencias, esta vista cambia por dentro; sus
-- columnas no.
-- -----------------------------------------------------------------------------
create or replace view v_today_tasks as
select t.id,
       t.title,
       t.priority,
       t.project_id,
       t.sort_order,
       t.due_date,
       (t.due_date at time zone coalesce(t.time_zone, app_timezone()))::date as due_day,
       (t.due_date at time zone coalesce(t.time_zone, app_timezone()))::date < app_today()
                                                                             as overdue,
       app_today()                                                           as day
from tasks t
where t.completed_time is null
  and t.due_date is not null
  and (t.due_date at time zone coalesce(t.time_zone, app_timezone()))::date <= app_today();

comment on view v_today_tasks is
    'Tareas pendientes con vencimiento hoy o antes. Las vencidas se arrastran (overdue=true).';
