-- =============================================================================
-- 20260724120400_rpc_habits
--
-- El contrato de ESCRITURA de habitos. Toda la logica que antes vivia en el
-- daemon (calcular el siguiente valor, saber que dia es) vive aqui. Los
-- clientes pasan a ser renderizadores tontos.
--
-- Todas son `security definer`: se ejecutan con los permisos del propietario,
-- asi que funcionan aunque el rol `anon` no tenga acceso directo a las tablas.
-- `set search_path` es obligatorio en `security definer` para que nadie pueda
-- secuestrar la resolucion de nombres.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- habit_step -- avanza un habito un paso y devuelve el nuevo total
--
-- Es la operacion de "pulsar la tecla". Sustituye al patron leer-calcular-
-- escribir que hacia el daemon (`get_progress` -> `next_value` -> `checkin`):
-- ahora es atomico y no hay carrera si pulsas en el deck y en el movil a la vez.
--
-- weekly_quota : cada dia cuenta 1 (un dia de gym), idempotente dentro del dia.
-- Boolean      : salta directo a `goal` (es binario, no tiene sentido pasarse).
-- Real         : suma `step` SIN tope. 10/8 es un estado valido y deliberado.
-- -----------------------------------------------------------------------------
create or replace function habit_step(p_habit_id uuid)
    returns double precision
    language plpgsql
    security definer
    set search_path = public
as $$
declare
    h     habits%rowtype;
    v_new double precision;
begin
    select * into h from habits where id = p_habit_id and status = 0;
    if not found then
        raise exception 'Habito % inexistente o archivado', p_habit_id
            using errcode = 'no_data_found';
    end if;

    insert into habit_checkins (habit_id, checkin_date, value, goal, checkin_time, op_time)
    values (p_habit_id,
            app_today(),
            case
                when h.schedule_type = 'weekly_quota' then 1
                when h.type = 'Boolean'               then h.goal
                else h.step
            end,
            h.goal,
            now(),
            now())
    on conflict (habit_id, checkin_date) do update
        set value   = case
                          when h.schedule_type = 'weekly_quota' then 1
                          when h.type = 'Boolean'               then h.goal
                          else habit_checkins.value + h.step
                      end,
            goal    = h.goal,
            op_time = now()
    returning value into v_new;

    return v_new;
end;
$$;

comment on function habit_step(uuid) is
    'Avanza un paso (Boolean->goal, Real->+step sin tope, weekly_quota->1 el dia). Devuelve el nuevo total.';

-- -----------------------------------------------------------------------------
-- habit_set -- fija el total exacto de hoy (para la PWA / correcciones)
-- -----------------------------------------------------------------------------
create or replace function habit_set(p_habit_id uuid, p_value double precision)
    returns double precision
    language plpgsql
    security definer
    set search_path = public
as $$
declare
    h     habits%rowtype;
    v_new double precision;
begin
    select * into h from habits where id = p_habit_id and status = 0;
    if not found then
        raise exception 'Habito % inexistente o archivado', p_habit_id
            using errcode = 'no_data_found';
    end if;

    insert into habit_checkins (habit_id, checkin_date, value, goal, checkin_time, op_time)
    values (p_habit_id, app_today(), greatest(p_value, 0), h.goal, now(), now())
    on conflict (habit_id, checkin_date) do update
        set value   = greatest(p_value, 0),
            goal    = h.goal,
            op_time = now()
    returning value into v_new;

    return v_new;
end;
$$;

-- -----------------------------------------------------------------------------
-- habit_undo -- retrocede un paso (pulsacion accidental)
--
-- Devuelve el nuevo total, o 0 si hoy no habia checkin.
-- -----------------------------------------------------------------------------
create or replace function habit_undo(p_habit_id uuid)
    returns double precision
    language plpgsql
    security definer
    set search_path = public
as $$
declare
    h     habits%rowtype;
    v_new double precision;
begin
    select * into h from habits where id = p_habit_id;
    if not found then
        raise exception 'Habito % inexistente', p_habit_id using errcode = 'no_data_found';
    end if;

    update habit_checkins
       set value   = case
                         when h.type = 'Boolean' then 0
                         else greatest(value - h.step, 0)
                     end,
           op_time = now()
     where habit_id = p_habit_id
       and checkin_date = app_today()
    returning value into v_new;

    return coalesce(v_new, 0);
end;
$$;
