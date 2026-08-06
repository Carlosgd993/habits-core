-- =============================================================================
-- 20260806120000_instantiate_task_dedup.sql
--
-- instantiate_task deja de poder duplicar ocurrencias. Antes creaba una fila
-- nueva en cada llamada (documentado como "no idempotente"); un boton de
-- creacion rapida en un cliente que no vea una ocurrencia futura ya
-- encadenada (chain_next_occurrence la crea por adelantado, con due_date
-- dentro de interval_n dias) podia acabar creando una segunda para la misma
-- plantilla.
--
-- Ahora, si ya hay una ocurrencia pendiente (ni completada ni omitida) de esa
-- plantilla, no se inserta otra: se adelanta el due_date de la existente a
-- coalesce(p_due, now()) y se devuelve su id. El resto de la fila no se toca.
--
-- No cambia la firma ni los grants (create or replace los conserva).
-- =============================================================================
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

    -- task_templates.project_id es nullable pero tasks.project_id no lo es:
    -- sin esta guarda seria un 23502 cripitico.
    if tpl.project_id is null then
        raise exception 'La plantilla % no tiene proyecto asignado', p_template_id
            using errcode = 'no_data_found';
    end if;

    -- Como mucho una ocurrencia pendiente por plantilla: si ya hay una, se
    -- adelanta en vez de duplicar.
    select id into new_id
      from tasks
     where template_id = p_template_id
       and completed_time is null
       and skipped_time is null
     limit 1;

    if found then
        update tasks set due_date = coalesce(p_due, now()) where id = new_id;
        return new_id;
    end if;

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
    'Si ya hay una pendiente de esa plantilla, no duplica: adelanta su due_date '
    'a coalesce(p_due, now()) y devuelve su id. Sin p_due vence ahora, para que '
    'sea visible en v_today_tasks.';
