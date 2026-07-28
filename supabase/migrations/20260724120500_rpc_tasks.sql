-- =============================================================================
-- 20260724120500_rpc_tasks
--
-- El contrato de ESCRITURA de tareas: el ciclo de vida completo de una
-- ocurrencia (crearla desde plantilla, cerrarla, omitirla y sus reversos).
--
-- Todas son `security definer` con `set search_path`, por lo mismo que las de
-- habitos: funcionan sin que `anon` toque las tablas.
--
-- instantiate_task va primero porque complete_task la llama.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- instantiate_task -- crea UNA ocurrencia a partir de una plantilla
--
-- Copia las subtareas del JSON de la plantilla a checklist_items. Devuelve el
-- id de la ocurrencia nueva. Es el "solo hay que crear un registro y arrastra
-- todo lo de esa tarea": la llaman pg_cron (fijas), complete_task (deslizantes)
-- y el usuario/app (repetibles sin tiempo).
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

    insert into tasks (project_id, template_id, title, priority, due_date)
    values (tpl.project_id, tpl.id, tpl.title, tpl.priority, p_due)
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
    'Crea una ocurrencia (tasks) desde una plantilla, copiando sus subtareas. Devuelve el id nuevo.';

-- -----------------------------------------------------------------------------
-- chain_next_occurrence -- la regla deslizante, en UN solo sitio
--
-- Cerrar una ocurrencia (complete_task) y omitirla (skip_task) son lo mismo de
-- cara a la recurrencia: la tarea deja de estar pendiente, asi que toca
-- programar la siguiente. Lo unico que cambia entre ambas es el rastro que
-- queda en la historia. Por eso la regla vive aqui y no duplicada en las dos.
--
-- Solo encadenan las plantillas `interval_completion` (deslizantes: regar las
-- plantas 3 dias DESPUES de regarlas), y la siguiente ocurrencia se cuenta
-- DESDE AHORA, no del calendario.
--
-- Filtra por `active`: desactivar una plantilla es como se para una recurrencia,
-- y entonces esto no hace nada. Sin ese filtro, instantiate_task lanzaria
-- excepcion y la transaccion entera (incluido el cierre de la tarea) haria
-- rollback -> una plantilla desactivada dejaria su ultima ocurrencia imposible
-- de cerrar.
--
-- NO se concede a anon: es interna, se llama solo desde complete_task/skip_task.
-- -----------------------------------------------------------------------------
create or replace function chain_next_occurrence(p_template_id uuid)
    returns uuid
    language plpgsql
    security definer
    set search_path = public
as $$
declare
    v_stype    text;
    v_interval integer;
begin
    if p_template_id is null then
        return null;  -- tarea unica, sin plantilla: nada que encadenar
    end if;

    select schedule_type, interval_n into v_stype, v_interval
      from task_templates
     where id = p_template_id
       and active;

    if v_stype is distinct from 'interval_completion' then
        return null;  -- inactiva, inexistente, o no deslizante
    end if;

    return instantiate_task(p_template_id, now() + make_interval(days => v_interval));
end;
$$;

comment on function chain_next_occurrence(uuid) is
    'Si la plantilla es deslizante y esta activa, crea la siguiente ocurrencia a interval_n '
    'dias desde ahora. Interna: la usan complete_task y skip_task. Devuelve el id nuevo o null.';

-- -----------------------------------------------------------------------------
-- complete_task -- cierra una ocurrencia, y si es deslizante crea la siguiente
--
-- Marca `completed_time` y mueve `status_id` al estado con `is_done`: el cliente
-- no conoce ningun UUID de `statuses`.
--
-- Idempotente: llamarla dos veces no reescribe la hora de completado ni duplica
-- la ocurrencia siguiente.
-- -----------------------------------------------------------------------------
create or replace function complete_task(p_task_id uuid)
    returns void
    language plpgsql
    security definer
    set search_path = public
as $$
declare
    v_done     uuid;
    v_template uuid;
begin
    select id into v_done from statuses where is_done limit 1;

    update tasks
       set completed_time = now(),
           status_id      = coalesce(v_done, status_id)
     where id = p_task_id
       and completed_time is null
       and skipped_time is null
    returning template_id into v_template;

    if not found then
        return;  -- ya cerrada/omitida o inexistente: idempotente
    end if;

    perform chain_next_occurrence(v_template);
end;
$$;

comment on function complete_task(uuid) is
    'Cierra una ocurrencia. Idempotente. Si la plantilla es deslizante, crea la siguiente.';

-- -----------------------------------------------------------------------------
-- uncomplete_task -- reabre una tarea
-- -----------------------------------------------------------------------------
create or replace function uncomplete_task(p_task_id uuid)
    returns void
    language plpgsql
    security definer
    set search_path = public
as $$
begin
    update tasks
       set completed_time = null,
           status_id      = null
     where id = p_task_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- skip_task / unskip_task -- "no me la tome" y su reverso
--
-- Omitir es HERMANO de completar, no lo contrario: la ocurrencia deja de estar
-- pendiente y la recurrencia sigue su curso igual (misma llamada a
-- chain_next_occurrence). Lo unico que cambia es el rastro historico: queda
-- constancia de que ese dia NO se hizo, en vez de que si.
--
-- Por eso tampoco toca `status_id`: omitida no es "hecha".
--
-- Idempotente: omitir dos veces no reescribe la hora ni duplica la siguiente.
-- -----------------------------------------------------------------------------
create or replace function skip_task(p_task_id uuid)
    returns void
    language plpgsql
    security definer
    set search_path = public
as $$
declare
    v_template uuid;
begin
    update tasks
       set skipped_time = now()
     where id = p_task_id
       and completed_time is null
       and skipped_time is null
    returning template_id into v_template;

    if not found then
        return;  -- ya cerrada/omitida o inexistente: idempotente
    end if;

    perform chain_next_occurrence(v_template);
end;
$$;

comment on function skip_task(uuid) is
    'Marca una ocurrencia como omitida (no se hizo) y, si la plantilla es deslizante, crea la '
    'siguiente igual que complete_task. Sale de la vista pero queda registrada. Idempotente.';

create or replace function unskip_task(p_task_id uuid)
    returns void
    language plpgsql
    security definer
    set search_path = public
as $$
begin
    update tasks set skipped_time = null where id = p_task_id;
end;
$$;
