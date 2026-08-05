-- =============================================================================
-- supabase/schemas/06_view_templates.sql
--
-- Definicion del ESTADO ACTUAL (no historia). Espejo de
-- supabase/migrations/20260724120300_view_templates.sql.
--
-- Contrato de LECTURA: las plantillas activas, para que los clientes las listen
-- y creen tareas a partir de ellas con instantiate_task(id).
--
-- Expone solo lo que hace falta para pintar una fila y llamar a la RPC: no saca
-- columnas operativas como anchor_date, times_of_day ni el jsonb crudo de
-- subtasks (de esas se encarga instantiate_task por dentro).
--
-- subtask_count evita mandar el jsonb entero al cliente solo para mostrar
-- "3 subtareas".
--
-- show_in_deck se expone como columna en vez de crear una vista aparte: el
-- cliente que solo quiere las de creacion rapida filtra con
-- ?show_in_deck=eq.true, y la PWA sigue viendo todas sin necesitar otro grant.
--
-- Si cambias algo aqui, cambia tambien la migration correspondiente en el
-- mismo commit -- no hay generacion automatica (no hay Supabase CLI instalado).
-- =============================================================================
create or replace view v_templates as
select t.id,
       t.title,
       t.project_id,
       t.priority,
       t.schedule_type,
       t.interval_n,
       t.bymonthday,
       jsonb_array_length(coalesce(t.subtasks, '[]'::jsonb)) as subtask_count,
       t.created_at,
       t.show_in_deck
  from task_templates t
 where t.active
 order by t.title;

comment on view v_templates is
    'Plantillas activas para que los clientes las listen y creen tareas via '
    'instantiate_task. show_in_deck marca las de creacion rapida (filtrar en el '
    'cliente). No expone la tabla: los clientes no tocan task_templates directamente.';
