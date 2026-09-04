-- =============================================================================
-- 20260904120000_timer_daily_totals
--
-- Nueva vista de lectura: v_timer_daily_totals, tiempo acumulado HOY por
-- tarea o etiqueta de cronometro. La pide el deck para pintar en la propia
-- tecla, cuando esta parada, cuanto tiempo se le ha dedicado hoy (p.ej.
-- "[00:25] Lectura") -- sin esto el cliente solo veia el tiempo transcurrido
-- mientras corria, y lo perdia al parar.
--
-- Una fila por (task_id, label_id) con al menos un bloque (time_entries) hoy,
-- sumando segundos. "Hoy" es el dia de app_timezone(), igual que el resto del
-- contrato -- ningun cliente decide fechas. Un bloque que siga corriendo
-- cuenta hasta ahora mismo (coalesce con now()), aunque en la practica el
-- cliente solo consulta este total mientras la tarea/etiqueta esta parada.
--
-- Contenido:
--   1. Vista nueva: v_timer_daily_totals.
--   2. Grant nuevo (la vista nace cerrada a anon, como cualquier objeto nuevo).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Vista nueva
-- -----------------------------------------------------------------------------
create or replace view v_timer_daily_totals as
select te.task_id, te.label_id,
       sum(extract(epoch from (coalesce(te.stopped_at, now()) - te.started_at)))::bigint as seconds_today
  from time_entries te
 where (te.task_id is not null or te.label_id is not null)
   and (te.started_at at time zone app_timezone())::date = app_today()
 group by te.task_id, te.label_id;

comment on view v_timer_daily_totals is
    'Segundos acumulados hoy por tarea/etiqueta (una fila por cada una con '
    'al menos un bloque hoy). task_id/label_id son mutuamente excluyentes, '
    'igual que en v_running_timer. Un bloque que siga corriendo cuenta hasta '
    'ahora mismo (coalesce con now()).';

-- -----------------------------------------------------------------------------
-- 2. Grant
-- -----------------------------------------------------------------------------
grant select on v_timer_daily_totals to anon;
