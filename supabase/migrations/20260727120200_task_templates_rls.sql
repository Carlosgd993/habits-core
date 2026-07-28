-- =============================================================================
-- 20260727120200_task_templates_rls
--
-- Cierra el agujero que abrio 20260727120000: task_templates se creo DESPUES de
-- 20260724120300_rls_contract, asi que quedo fuera de aquella lista de tablas
-- con RLS. Sin esta migracion, la clave anon puede leer y escribir plantillas
-- directamente, saltandose el contrato.
--
-- Ademas expone el contrato de lectura que necesita la PWA: listar plantillas
-- para crear tareas a partir de ellas. Como siempre, via VISTA, no tabla.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Cerrar la tabla nueva, igual que las demas.
-- -----------------------------------------------------------------------------
alter table task_templates enable row level security;

revoke all on task_templates from anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. Red de seguridad permanente: activar RLS automaticamente en CUALQUIER
--    tabla futura del esquema public, para que no se repita este agujero.
--
--    Esto versiona en el repo lo que en el proyecto de test vivia solo como una
--    funcion suelta (rls_auto_enable) sin respaldo en migraciones. A partir de
--    aqui, crear una tabla la deja con RLS activado y sin politicas -> cerrada
--    por defecto. Los grants siguen siendo explicitos (paso 3).
-- -----------------------------------------------------------------------------
create or replace function rls_auto_enable()
    returns event_trigger
    language plpgsql
as $$
declare
    obj record;
begin
    for obj in
        select * from pg_event_trigger_ddl_commands()
        where command_tag = 'CREATE TABLE'
          and schema_name = 'public'
    loop
        execute format('alter table %s enable row level security', obj.object_identity);
    end loop;
end;
$$;

drop event trigger if exists trg_rls_auto_enable;
create event trigger trg_rls_auto_enable
    on ddl_command_end
    when tag in ('CREATE TABLE')
    execute function rls_auto_enable();

comment on function rls_auto_enable() is
    'Event trigger: activa RLS en toda tabla nueva de public. Red de seguridad '
    'para que ninguna tabla quede abierta por olvido, como paso con task_templates.';

-- -----------------------------------------------------------------------------
-- 3. Contrato de lectura para la PWA: v_templates.
--
--    La PWA lista plantillas activas para instanciar tareas. Expone solo lo que
--    necesita pintar una fila y llamar a instantiate_task(id): no filtra
--    columnas operativas como anchor_date o el jsonb crudo de subtasks (de
--    esas se encarga instantiate_task por dentro).
--
--    subtask_count evita mandar el jsonb entero al cliente solo para mostrar
--    "3 subtareas".
-- -----------------------------------------------------------------------------
create or replace view v_templates as
select t.id,
       t.title,
       t.project_id,
       t.priority,
       t.schedule_type,
       t.interval_n,
       t.bymonthday,
       jsonb_array_length(coalesce(t.subtasks, '[]'::jsonb)) as subtask_count,
       t.created_at
  from task_templates t
 where t.active
 order by t.title;

comment on view v_templates is
    'Plantillas activas para que la PWA liste y cree tareas via instantiate_task. '
    'No expone la tabla: los clientes no tocan task_templates directamente.';

grant select on v_templates to anon;

-- -----------------------------------------------------------------------------
-- 4. La PWA tambien necesita PODER crear una tarea desde una plantilla.
--    instantiate_task ya tiene grant execute (de 120100), pero lo re-confirmamos
--    aqui de forma explicita para dejar el contrato de plantillas junto.
-- -----------------------------------------------------------------------------
grant execute on function instantiate_task(uuid, timestamptz) to anon;
