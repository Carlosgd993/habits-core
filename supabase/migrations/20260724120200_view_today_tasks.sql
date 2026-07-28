-- =============================================================================
-- 20260724120200_view_today_tasks
--
-- Contrato de LECTURA: las ocurrencias pendientes de hoy o antes.
--
-- A diferencia de los habitos, una tarea SI arrastra: si vencia el lunes y no se
-- hizo, sigue apareciendo el jueves (`due_day <= hoy`), marcada con `overdue`.
--
-- Se excluyen:
--   - las hechas    (completed_time)
--   - las omitidas  (skipped_time): "no me la tome", no vuelve a salir
--   - las SIN fecha: con 12 teclas utiles en la Stream Deck, el inbox entero
--     inundaria la pantalla. Cuando haga falta, iran en una vista aparte
--     (`v_inbox_tasks`), no aqui.
--
-- El dia de vencimiento se calcula en la zona de la tarea si la tiene
-- (`time_zone`), y si no en la del ecosistema (`app_timezone()`).
-- =============================================================================
create or replace view v_today_tasks as
select t.id, t.title, t.priority, t.project_id, t.sort_order, t.due_date, t.template_id,
       (t.due_date at time zone coalesce(t.time_zone, app_timezone()))::date as due_day,
       (t.due_date at time zone coalesce(t.time_zone, app_timezone()))::date < app_today()
                                                                            as overdue,
       app_today()                                                          as day
  from tasks t
 where t.completed_time is null
   and t.skipped_time is null
   and t.due_date is not null
   and (t.due_date at time zone coalesce(t.time_zone, app_timezone()))::date <= app_today();

comment on view v_today_tasks is
    'Ocurrencias pendientes (ni hechas ni omitidas) con vencimiento hoy o antes. Las vencidas arrastran.';
