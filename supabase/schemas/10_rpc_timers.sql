-- =============================================================================
-- supabase/schemas/10_rpc_timers.sql
--
-- Definicion del ESTADO ACTUAL (no historia). Espejo de
-- supabase/migrations/<timestamp>_cronometros.sql.
--
-- El contrato de ESCRITURA de cronometros: una sola funcion, timer_toggle.
--
-- security definer con set search_path, por lo mismo que las de habitos y
-- tareas: funciona sin que `anon` toque las tablas.
--
-- Si cambias algo aqui, cambia tambien la migration correspondiente en el
-- mismo commit -- no hay generacion automatica (no hay Supabase CLI instalado).
-- No incluye grants: los concede la migration de esta feature, no
-- rls_contract.sql (que se mantiene fuera de schemas/ a proposito).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- timer_toggle -- arranca o para el cronometro de una tarea o una etiqueta
--
-- Recibe exactamente uno de los dos argumentos (nunca los dos, nunca
-- ninguno). El deck tiene un UNICO boton por tarea/etiqueta, no dos separados
-- de "iniciar"/"parar": esta funcion decide que toca mirando el estado REAL
-- en time_entries, nunca lo que el cliente cree -- el deck puede llevar hasta
-- REFRESH_SECONDS (15 min) sin refrescar, y con una sola tecla para las dos
-- direcciones un acierto de sentido importa mas que en habit_step (que
-- siempre suma).
--
-- Logica:
--   1. Si la tarea/etiqueta no existe o ya no es candidata (tarea cerrada u
--      omitida, etiqueta archivada), no hace nada -- no crea un cronometro
--      huerfano por un deck desincronizado.
--   2. Si YA es ella la que esta corriendo (misma tarea/etiqueta exacta), la
--      para.
--   3. Si no, para cualquier otro cronometro que estuviera corriendo (como
--      mucho uno a la vez, tipo Toggl) y arranca uno nuevo para esta.
--
-- title se denormaliza aqui, en el momento de arrancar (ver time_entries.title).
-- -----------------------------------------------------------------------------
create or replace function timer_toggle(p_task_id uuid default null, p_label_id uuid default null)
    returns void
    language plpgsql
    security definer
    set search_path = public
as $$
declare
    v_title   text;
    v_open_id uuid;
begin
    if (p_task_id is null) = (p_label_id is null) then
        raise exception 'timer_toggle necesita exactamente un p_task_id o p_label_id'
            using errcode = 'check_violation';
    end if;

    if p_task_id is not null then
        select title into v_title from tasks
         where id = p_task_id and completed_time is null and skipped_time is null;
    else
        select name into v_title from timer_labels
         where id = p_label_id and archived_at is null;
    end if;

    if v_title is null then
        return;  -- tarea cerrada/omitida, etiqueta archivada, o ninguna existe
    end if;

    select id into v_open_id from time_entries
     where stopped_at is null
       and task_id  is not distinct from p_task_id
       and label_id is not distinct from p_label_id;

    if v_open_id is not null then
        update time_entries set stopped_at = now() where id = v_open_id;
        return;
    end if;

    update time_entries set stopped_at = now() where stopped_at is null;

    insert into time_entries (task_id, label_id, title) values (p_task_id, p_label_id, v_title);
end;
$$;

comment on function timer_toggle(uuid, uuid) is
    'Alterna el cronometro de una tarea o una etiqueta (exactamente uno de '
    'los dos argumentos). Si ya era el que estaba corriendo, lo para; si no, '
    'para el que hubiera y arranca este. No falla sobre una tarea/etiqueta '
    'ya cerrada, archivada o inexistente: no hace nada.';
