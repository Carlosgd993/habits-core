-- =============================================================================
-- 20260903120000_cronometros
--
-- Nueva funcionalidad: cronometros tipo Toggl Track, aparte de habitos y
-- tareas. Un boton (tecla del deck) por tarea o por "etiqueta rapida"
-- predefinida (timer_labels, mismo patron que task_templates.show_in_deck)
-- que alterna: parado -> arranca, corriendo -> para. Como mucho un
-- cronometro corriendo a la vez, igual que Toggl. Objetivo: quedarse con
-- datos propios y privados de en que se va el tiempo, para poder cruzarlo mas
-- adelante con tareas/habitos/proyectos (sin dashboard todavia -- eso queda
-- para un cliente futuro, PWA/Grafana, ya en el roadmap).
--
-- Nota de alcance: docs/estructura-bd.md documentaba la exclusion explicita
-- de "Focus/Pomodoro/Timing". Esto no es eso -- no hay tecnica Pomodoro, es
-- solo llevar la cuenta de en que se invierte el tiempo. Esta migration
-- actualiza esa nota.
--
-- Contenido, en orden:
--   1. Tablas: timer_labels (catalogo de etiquetas), time_entries (bloques
--      de tiempo), con el indice unico parcial que garantiza un solo
--      cronometro corriendo a la vez.
--   2. Vistas de lectura: v_timer_labels, v_running_timer.
--   3. RPC nueva: timer_toggle -- decide start-vs-stop mirando el estado
--      real, nunca lo que el cliente cree (el deck puede llevar hasta 15 min
--      sin refrescar).
--   4. RPC modificadas (create or replace, misma firma -> conservan sus
--      grants): complete_task y skip_task paran el cronometro de la tarea si
--      seguia corriendo -- si no, quedaria corriendo para siempre en cuanto
--      la tarea sale de v_today_tasks.
--   5. Grants nuevos (timer_labels/time_entries nacen cerradas via
--      trg_rls_auto_enable, como cualquier tabla nueva; solo las vistas y la
--      RPC nueva necesitan grant explicito).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Tablas
-- -----------------------------------------------------------------------------
create table timer_labels (
    id           uuid primary key default gen_random_uuid(),
    name         text not null,
    color        text,
    sort_order   bigint not null default 0,
    show_in_deck boolean not null default false,
    archived_at  timestamptz,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now()
);

comment on column timer_labels.show_in_deck is
    'Si true, la etiqueta se ofrece como boton de acceso rapido en la vista '
    '"Cronometros" de la Stream Deck. Opt-in explicito, igual que '
    'task_templates.show_in_deck: una etiqueta nueva no aparece sola.';
comment on column timer_labels.color is
    '"#RRGGBB", opcional. Ningun cliente actual lo usa para pintar (el deck '
    'distingue solo corriendo/parado); reservado para un cliente de analitica futuro.';

create table time_entries (
    id         uuid primary key default gen_random_uuid(),
    task_id    uuid references tasks (id) on delete set null,
    label_id   uuid references timer_labels (id) on delete set null,
    title      text not null,
    started_at timestamptz not null default now(),
    stopped_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint time_entries_task_xor_label_chk check (task_id is null or label_id is null)
);

create index idx_time_entries_task_id    on time_entries (task_id);
create index idx_time_entries_label_id   on time_entries (label_id);
create index idx_time_entries_started_at on time_entries (started_at);

create unique index time_entries_single_running_idx on time_entries ((true)) where stopped_at is null;

comment on column time_entries.stopped_at is
    'NULL = el cronometro sigue corriendo. Como mucho una fila de toda la '
    'tabla puede tenerlo a NULL (time_entries_single_running_idx).';
comment on column time_entries.title is
    'Denormalizado al arrancar desde tasks.title o timer_labels.name: conserva '
    'el titulo de su momento aunque la tarea/etiqueta cambie despues.';

create trigger trg_timer_labels_updated before update on timer_labels for each row execute function set_updated_at();
create trigger trg_time_entries_updated before update on time_entries for each row execute function set_updated_at();

-- -----------------------------------------------------------------------------
-- 2. Vistas de lectura
-- -----------------------------------------------------------------------------
create or replace view v_timer_labels as
select l.id, l.name, l.color, l.sort_order, l.show_in_deck
  from timer_labels l
 where l.archived_at is null
 order by l.sort_order, l.name;

comment on view v_timer_labels is
    'Etiquetas de cronometro activas (no archivadas). show_in_deck marca las '
    'de acceso rapido -- filtrar en el cliente, igual que v_templates.show_in_deck.';

create or replace view v_running_timer as
select te.id, te.task_id, te.label_id, te.title, te.started_at
  from time_entries te
 where te.stopped_at is null;

comment on view v_running_timer is
    'El cronometro en marcha ahora mismo (0 o 1 fila). task_id/label_id dicen '
    'a que esta asociado (a lo sumo uno de los dos, o ninguno). started_at es '
    'la unica fuente para calcular el tiempo transcurrido -- ningun cliente '
    'lleva su propio contador.';

-- -----------------------------------------------------------------------------
-- 3. RPC nueva -- timer_toggle
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

-- -----------------------------------------------------------------------------
-- 4. RPC modificadas -- complete_task / skip_task paran el cronometro
--    de la tarea si seguia corriendo (misma firma, conservan sus grants)
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

    update time_entries set stopped_at = now()
     where task_id = p_task_id and stopped_at is null;

    perform chain_next_occurrence(v_template);
end;
$$;

comment on function complete_task(uuid) is
    'Cierra una ocurrencia. Idempotente. Si la plantilla es deslizante, crea la siguiente. '
    'Para tambien el cronometro de esta tarea si seguia corriendo.';

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

    update time_entries set stopped_at = now()
     where task_id = p_task_id and stopped_at is null;

    perform chain_next_occurrence(v_template);
end;
$$;

comment on function skip_task(uuid) is
    'Marca una ocurrencia como omitida (no se hizo) y, si la plantilla es deslizante, crea la '
    'siguiente igual que complete_task. Sale de la vista pero queda registrada. Idempotente. '
    'Para tambien el cronometro de esta tarea si seguia corriendo.';

-- -----------------------------------------------------------------------------
-- 5. Grants -- timer_labels/time_entries nacen cerradas solas via
--    trg_rls_auto_enable (RLS activo, sin politica). complete_task/skip_task
--    ya estaban concedidas y create or replace las conserva. Solo hace falta
--    conceder lo nuevo.
-- -----------------------------------------------------------------------------
grant select on v_timer_labels to anon;
grant select on v_running_timer to anon;
grant execute on function timer_toggle(uuid, uuid) to anon;
