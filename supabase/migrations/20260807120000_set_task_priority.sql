-- =============================================================================
-- 20260807120000_set_task_priority
--
-- Nueva capacidad: cambiar la prioridad de una ocurrencia ya creada. La pide
-- el menu de opciones de una tarea (mantener pulsado) en la Stream Deck
-- (../streamdeck-habits), que hasta ahora era un prototipo sin ninguna accion
-- real.
--
-- Funcion nueva -> a diferencia de 20260805120000_plantillas_deck y
-- 20260806130000_habit_manual_entry (que reutilizaban funciones/vistas ya
-- concedidas), esta SI necesita su propio `grant`: no hay ningun `create or
-- replace function set_task_priority` previo del que heredarlo.
-- =============================================================================

create or replace function set_task_priority(p_task_id uuid, p_priority smallint)
    returns void
    language plpgsql
    security definer
    set search_path = public
as $$
begin
    if p_priority not in (0, 1, 3, 5) then
        raise exception 'Prioridad % invalida (solo 0, 1, 3 o 5)', p_priority
            using errcode = 'check_violation';
    end if;

    update tasks
       set priority = p_priority
     where id = p_task_id
       and completed_time is null
       and skipped_time is null;
end;
$$;

comment on function set_task_priority(uuid, smallint) is
    'Cambia la prioridad (0/1/3/5) de una ocurrencia pendiente. No hace nada si '
    'ya esta completada u omitida, o si no existe.';

grant execute on function set_task_priority(uuid, smallint) to anon;
