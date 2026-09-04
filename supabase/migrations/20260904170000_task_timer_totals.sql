-- =============================================================================
-- 20260904170000_task_timer_totals
--
-- Nueva vista de lectura: v_task_timer_totals, tiempo acumulado de SIEMPRE
-- por tarea (no por dia, al reves que v_timer_daily_totals). La pide el deck
-- para pintar en la propia tecla de una tarea, en "Hoy"/"Tareas", cuanto
-- tiempo se le ha dedicado en total -- sin filtrar por dia: una tarea es una
-- ocurrencia concreta, no un cajon recurrente como una etiqueta, asi que lo
-- que importa ahi es el acumulado mientras estuvo abierta, no "hoy".
--
-- Una fila por task_id con al menos un bloque en time_entries, sumando
-- segundos. Un bloque que siga corriendo cuenta hasta ahora mismo (coalesce
-- con now()).
--
-- Contenido:
--   1. Vista nueva: v_task_timer_totals.
--   2. Grant nuevo (la vista nace cerrada a anon, como cualquier objeto nuevo).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Vista nueva
-- -----------------------------------------------------------------------------
create or replace view v_task_timer_totals as
select te.task_id,
       sum(extract(epoch from (coalesce(te.stopped_at, now()) - te.started_at)))::bigint as seconds_total
  from time_entries te
 where te.task_id is not null
 group by te.task_id;

comment on view v_task_timer_totals is
    'Segundos acumulados de SIEMPRE por tarea (todos sus bloques de '
    'time_entries, sin filtrar por dia -- al reves que v_timer_daily_totals). '
    'Una fila por task_id con al menos un bloque. Un bloque que siga '
    'corriendo cuenta hasta ahora mismo (coalesce con now()).';

-- -----------------------------------------------------------------------------
-- 2. Grant
-- -----------------------------------------------------------------------------
grant select on v_task_timer_totals to anon;
