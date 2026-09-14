-- =============================================================================
-- supabase/migrations/20260914120000_view_today_tasks_project_name.sql
--
-- Expone project_name (nombre de projects) en v_today_tasks, resuelto via
-- join, para que un cliente pueda filtrar/agrupar tareas por proyecto sin
-- tener que resolver el UUID crudo de project_id por su cuenta (p.ej. una
-- vista nueva del deck que muestre solo las tareas de un proyecto dado por
-- nombre) -- mismo patron que 20260910120000_view_today_habits_section_name.sql
-- aplico para section_name en v_today_habits.
--
-- No se toca v_templates: fuera de alcance de este cambio.
-- =============================================================================

-- project_name va al FINAL de la lista de columnas a proposito: Postgres no
-- admite insertar una columna nueva en medio de una vista via
-- `create or replace view` (lo trata como un rename de la columna que ocupaba
-- esa posicion y falla con "cannot change name of view column"). Columnas de
-- t. calificadas porque el join introduce id/sort_order duplicados
-- (tarea vs proyecto).
create or replace view v_today_tasks as
select t.id, t.title, t.priority, t.project_id, t.sort_order, t.due_date, t.template_id,
       (t.due_date at time zone coalesce(t.time_zone, app_timezone()))::date as due_day,
       (t.due_date at time zone coalesce(t.time_zone, app_timezone()))::date < app_today()
                                                                            as overdue,
       app_today()                                                          as day,
       p.name                                                               as project_name
  from tasks t
  left join projects p on p.id = t.project_id
 where t.completed_time is null
   and t.skipped_time is null
   and t.due_date is not null
   and (t.due_date at time zone coalesce(t.time_zone, app_timezone()))::date <= app_today();

comment on view v_today_tasks is
    'Ocurrencias pendientes (ni hechas ni omitidas) con vencimiento hoy o antes. Las vencidas '
    'arrastran. project_name resuelve el nombre de projects (NULL si el project_id no resuelve).';
