-- =============================================================================
-- 20260805120000_plantillas_deck
--
-- Creacion rapida de tareas desde plantilla, para la pantalla "Crear" de la
-- Stream Deck (y cualquier cliente futuro que quiera lo mismo).
--
-- El caso de uso son las tareas que se repiten pero NO tienen momento fijo
-- ("Cita peluquero"): no las materializa pg_cron ni las encadena complete_task,
-- las crea el usuario cuando le toca. La infraestructura ya existia entera
-- (task_templates + v_templates + instantiate_task, todas con su grant), pero
-- le faltaban dos piezas, que son justo lo que hace este fichero:
--
--   1. Una forma de marcar QUE plantillas se ofrecen como boton (show_in_deck).
--   2. Que la ocurrencia creada sea VISIBLE: instantiate_task la dejaba con
--      due_date null y v_today_tasks excluye las tareas sin fecha, asi que
--      nacia invisible en todos los clientes.
--
-- OJO: este fichero es un delta, a diferencia de los 9 anteriores. Se aplica
-- sobre una base que ya tiene el esquema completo. El estado final vive, como
-- siempre, en supabase/schemas/ (02, 06 y 08 ya lo reflejan).
--
-- No hace falta ningun grant nuevo: `create or replace` conserva los de
-- 20260724120600_rls_contract.sql, y ni la vista ni la funcion cambian de
-- firma.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. task_templates.show_in_deck -- que plantillas son "creacion rapida"
--
-- Eje independiente de `active` y de `schedule_type`: una plantilla puede estar
-- activa y no ofrecerse como boton (p.ej. las interval_calendar, que las
-- materializara pg_cron). Default false = opt-in explicito: una plantilla nueva
-- no aparece sola en ningun sitio.
--
-- Sin indice a proposito: la tabla es de decenas de filas y v_templates ya
-- filtra por `active`, que si lo tiene.
-- -----------------------------------------------------------------------------
alter table task_templates
    add column show_in_deck boolean not null default false;

comment on column task_templates.show_in_deck is
    'Si true, la plantilla se ofrece como boton de creacion rapida en los clientes '
    '(pantalla "Crear" de la Stream Deck). Independiente de active y de schedule_type: '
    'opt-in explicito, una plantilla nueva no aparece sola.';

-- -----------------------------------------------------------------------------
-- 2. v_templates -- exponer show_in_deck
--
-- Columna AÑADIDA AL FINAL: `create or replace view` no deja reordenar ni
-- quitar, y la regla 1 del contrato tampoco. El filtrado lo hace el cliente
-- (?show_in_deck=eq.true) en vez de crearse una vista nueva: asi la PWA sigue
-- viendo todas las plantillas activas y no hace falta otro grant.
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
       t.created_at,
       t.show_in_deck
  from task_templates t
 where t.active
 order by t.title;

comment on view v_templates is
    'Plantillas activas para que los clientes las listen y creen tareas via '
    'instantiate_task. show_in_deck marca las de creacion rapida (filtrar en el '
    'cliente). No expone la tabla: los clientes no tocan task_templates directamente.';

-- -----------------------------------------------------------------------------
-- 3. instantiate_task -- vencimiento por defecto = ahora, y guarda de proyecto
--
-- Cambian dos cosas del cuerpo (la firma no, asi que el grant sigue valiendo):
--
--   * `coalesce(p_due, now())`: sin esto la ocurrencia nacia con due_date null
--     y v_today_tasks la excluye -- el usuario pulsaba el boton y no pasaba
--     nada visible. Que la fecha la ponga la base y no el cliente es la regla 3
--     del contrato. chain_next_occurrence no se entera: ya pasa p_due explicito.
--
--   * La guarda de project_id: task_templates.project_id es nullable pero
--     tasks.project_id es not null, asi que una plantilla sin proyecto reventaba
--     con un 23502 cripitico. Ahora falla como las demas, con no_data_found y un
--     mensaje que dice que arreglar.
-- -----------------------------------------------------------------------------
create or replace function instantiate_task(p_template_id uuid, p_due timestamptz default null)
    returns uuid
    language plpgsql
    security definer
    set search_path = public
as $$
declare
    tpl    task_templates%rowtype;
    new_id uuid;
    item   jsonb;
begin
    select * into tpl from task_templates where id = p_template_id and active;
    if not found then
        raise exception 'Plantilla % inexistente o inactiva', p_template_id
            using errcode = 'no_data_found';
    end if;

    if tpl.project_id is null then
        raise exception 'La plantilla % no tiene proyecto asignado', p_template_id
            using errcode = 'no_data_found';
    end if;

    -- Sin fecha explicita, la ocurrencia vence ahora: si no, due_date queda null
    -- y no aparece en v_today_tasks (no hay inbox todavia).
    insert into tasks (project_id, template_id, title, priority, due_date)
    values (tpl.project_id, tpl.id, tpl.title, tpl.priority, coalesce(p_due, now()))
    returning id into new_id;

    for item in select * from jsonb_array_elements(coalesce(tpl.subtasks, '[]'::jsonb))
    loop
        insert into checklist_items (task_id, title, sort_order)
        values (new_id,
                coalesce(item ->> 'title', item #>> '{}'),
                coalesce((item ->> 'sort_order')::bigint, 0));
    end loop;

    return new_id;
end;
$$;

comment on function instantiate_task(uuid, timestamptz) is
    'Crea una ocurrencia (tasks) desde una plantilla, copiando sus subtareas. '
    'Sin p_due vence ahora, para que sea visible en v_today_tasks. Devuelve el id nuevo.';
