-- =============================================================================
-- supabase/schemas/02_tables.sql
--
-- Definicion del ESTADO ACTUAL (no historia). Espejo de las secciones 2 y 3 de
-- supabase/migrations/20260724115900_init.sql: las 11 tablas, sus indices,
-- constraints y triggers de updated_at.
--
-- NO incluye la semilla minima (insert into statuses...) del final de esa
-- migration: es DML, no definicion estructural. Ver el procedimiento de
-- reconstruccion desde cero en CLAUDE.md, que la aplica aparte.
--
-- Si cambias algo aqui, cambia tambien la migration correspondiente en el
-- mismo commit -- no hay generacion automatica (no hay Supabase CLI instalado).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- project_groups -- carpetas de proyectos
-- -----------------------------------------------------------------------------
create table project_groups (
    id         uuid primary key default gen_random_uuid(),
    name       text not null,
    sort_order bigint not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- projects -- proyectos / listas
-- -----------------------------------------------------------------------------
create table projects (
    id         uuid primary key default gen_random_uuid(),
    name       text not null,
    color      text,
    sort_order bigint not null default 0,
    closed     boolean not null default false,
    group_id   uuid references project_groups (id) on delete set null,
    view_mode  text not null default 'list',
    kind       text not null default 'TASK',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint projects_view_mode_chk check (view_mode in ('list', 'kanban', 'timeline')),
    constraint projects_kind_chk      check (kind in ('TASK', 'NOTE'))
);

create index idx_projects_group_id on projects (group_id);

-- -----------------------------------------------------------------------------
-- statuses -- catalogo libre de estados de tarea
--
-- `is_done` marca cual de los estados cierra una tarea. Sin esa columna,
-- complete_task() tendria que conocer un UUID concreto, y ese UUID acabaria
-- copiado en el .env de la Pi, en la PWA y en el bot.
--
-- El indice parcial unico garantiza que solo haya UN estado "hecho".
-- -----------------------------------------------------------------------------
create table statuses (
    id         uuid primary key default gen_random_uuid(),
    name       text not null,
    color      text,
    sort_order bigint not null default 0,
    is_done    boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create unique index statuses_single_done_idx on statuses (is_done) where is_done;

comment on column statuses.is_done is
    'true en el (unico) estado que representa "tarea completada".';

-- -----------------------------------------------------------------------------
-- habit_sections -- secciones de habitos
-- -----------------------------------------------------------------------------
create table habit_sections (
    id         uuid primary key default gen_random_uuid(),
    name       text not null,
    sort_order bigint not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- habits -- habitos
--
-- Dos ejes ortogonales:
--   QUE mides   -> type (Boolean / Real)
--   CUANDO toca -> schedule_type + sus parametros (interval_n, byday,
--                  bymonthday, anchor_date)
--
-- `purpose` separa el habito con objetivo del de solo registro: un 'log'
-- ("bebi cocacola") nunca sale como pendiente, pero vive en esta misma tabla
-- para no partir el pipeline de checkins ni la analitica.
--
-- No hay `repeat_rule` (texto RRULE): la recurrencia vive en schedule_type.
-- -----------------------------------------------------------------------------
create table habits (
    id                uuid primary key default gen_random_uuid(),
    name              text not null,
    icon_res          text,
    color             text,
    sort_order        bigint not null default 0,
    status            smallint not null default 0,
    encouragement     text,
    type              text not null default 'Boolean',
    goal              double precision not null default 1,
    step              double precision not null default 1,
    unit              text,
    reminders         text[] not null default '{}',
    record_enable     boolean not null default false,
    section_id        uuid references habit_sections (id) on delete set null,
    target_days       integer not null default 0,
    target_start_date date,
    completed_cycles  integer not null default 0,
    ex_dates          date[] not null default '{}',
    style             smallint not null default 0,
    archived_at       timestamptz,

    purpose           text not null default 'goal',
    schedule_type     text,
    interval_n        integer not null default 1,
    byday             smallint[] not null default '{}',
    bymonthday        smallint,
    anchor_date       date,

    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now(),

    constraint habits_type_chk       check (type in ('Boolean', 'Real')),
    constraint habits_purpose_chk    check (purpose in ('goal', 'log')),
    constraint habits_interval_n_chk check (interval_n >= 1),
    constraint habits_bymonthday_chk check (bymonthday is null or bymonthday between 1 and 31),
    constraint habits_schedule_type_chk
        check (schedule_type is null or schedule_type in
               ('interval_calendar', 'weekly_days', 'weekly_quota', 'monthly_day')),
    -- Un habito 'goal' DEBE tener programacion; un 'log' la ignora.
    constraint habits_goal_needs_schedule_chk
        check (purpose = 'log' or schedule_type is not null)
);

create index idx_habits_section_id on habits (section_id);

comment on column habits.purpose is
    '''goal'' = habito con objetivo, sale en v_today_habits los dias que toca. '
    '''log'' = solo registro (p.ej. "bebi cocacola"), nunca pendiente; sale en v_log_habits.';
comment on column habits.schedule_type is
    'interval_calendar (n dias desde anchor_date; n=1 = diario) | weekly_days (byday, isodow 1..7) '
    '| weekly_quota (goal = veces por semana, cualquier dia) | monthly_day (bymonthday).';
comment on column habits.byday is 'weekly_days: dias ISO (1=lunes .. 7=domingo).';

-- -----------------------------------------------------------------------------
-- habit_checkins -- registro diario de un habito
--
-- Un checkin por habito y dia (unique). `value` puede superar a `goal`: 10/8 es
-- un estado valido y deliberado.
-- -----------------------------------------------------------------------------
create table habit_checkins (
    id           uuid primary key default gen_random_uuid(),
    habit_id     uuid not null references habits (id) on delete cascade,
    checkin_date date not null,
    checkin_time timestamptz,
    op_time      timestamptz,
    value        double precision not null default 1,
    goal         double precision not null default 1,
    status       smallint,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now(),

    constraint habit_checkins_habit_day_uk unique (habit_id, checkin_date)
);

create index idx_habit_checkins_habit_id on habit_checkins (habit_id);

-- -----------------------------------------------------------------------------
-- task_templates -- la definicion reutilizable de una tarea
--
-- Una plantilla NO tiene due_date ni completed_time (eso es de la ocurrencia).
-- `subtasks` es un array JSON de objetos {"title": "...", "sort_order": n};
-- instantiate_task los copia a checklist_items de la ocurrencia nueva.
-- `times_of_day` sirve para materializar VARIAS ocurrencias el mismo dia
-- (pastilla 09:00/14:00/21:00) sin inventar un schedule_type intradia.
-- -----------------------------------------------------------------------------
create table task_templates (
    id            uuid primary key default gen_random_uuid(),
    title         text not null,
    project_id    uuid references projects (id) on delete set null,
    priority      smallint not null default 0,
    subtasks      jsonb not null default '[]',
    schedule_type text not null default 'none',
    interval_n    integer not null default 1,
    bymonthday    smallint,
    times_of_day  time[] not null default '{}',
    anchor_date   date,
    active        boolean not null default true,
    show_in_deck  boolean not null default false,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),

    constraint task_templates_priority_chk   check (priority in (0, 1, 3, 5)),
    constraint task_templates_interval_n_chk check (interval_n >= 1),
    constraint task_templates_bymonthday_chk check (bymonthday is null or bymonthday between 1 and 31),
    constraint task_templates_schedule_type_chk
        check (schedule_type in ('interval_calendar', 'interval_completion', 'monthly_day', 'none'))
);

create index idx_task_templates_active on task_templates (active);

comment on table task_templates is
    'Definicion reutilizable de una tarea. Las ocurrencias concretas viven en tasks. '
    'schedule_type: interval_calendar (fija, materializa pg_cron) | interval_completion '
    '(deslizante, la crea complete_task) | monthly_day | none (manual / repetible sin tiempo).';
comment on column task_templates.subtasks is
    'Array JSON de subtareas: [{"title": "...", "sort_order": 0}, ...]. Se copian al instanciar.';
comment on column task_templates.times_of_day is
    'Horas fijas para materializar varias ocurrencias el mismo dia (p.ej. pastilla 09/14/21).';
comment on column task_templates.show_in_deck is
    'Si true, la plantilla se ofrece como boton de creacion rapida en los clientes '
    '(pantalla "Crear" de la Stream Deck). Independiente de active y de schedule_type: '
    'opt-in explicito, una plantilla nueva no aparece sola.';

-- -----------------------------------------------------------------------------
-- tasks -- las OCURRENCIAS concretas
--
-- Tres estados terminales posibles:
--   pendiente : completed_time is null and skipped_time is null
--   hecha     : completed_time
--   omitida   : skipped_time ("no me la tome": sale de la vista, pero queda
--               registrado que NO se hizo)
--
-- No hay `repeat_rule`: la recurrencia vive en task_templates.
-- -----------------------------------------------------------------------------
create table tasks (
    id             uuid primary key default gen_random_uuid(),
    project_id     uuid not null references projects (id) on delete cascade,
    status_id      uuid references statuses (id) on delete set null,
    template_id    uuid references task_templates (id) on delete set null,
    title          text not null,
    content        text,
    description    text,
    is_all_day     boolean not null default false,
    start_date     timestamptz,
    due_date       timestamptz,
    time_zone      text,
    reminders      text[] not null default '{}',
    priority       smallint not null default 0,
    completed_time timestamptz,
    skipped_time   timestamptz,
    sort_order     bigint not null default 0,
    kind           text not null default 'TEXT',
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now(),

    constraint tasks_priority_chk check (priority in (0, 1, 3, 5)),
    constraint tasks_kind_chk     check (kind in ('TEXT', 'NOTE', 'CHECKLIST')),
    -- Una ocurrencia no puede estar a la vez hecha y omitida.
    constraint tasks_done_xor_skip_chk
        check (completed_time is null or skipped_time is null)
);

create index idx_tasks_project_id  on tasks (project_id);
create index idx_tasks_status_id   on tasks (status_id);
create index idx_tasks_template_id on tasks (template_id);
create index idx_tasks_due_date    on tasks (due_date);

comment on column tasks.template_id is
    'Plantilla de la que nace la ocurrencia. NULL = tarea unica (sin plantilla).';
comment on column tasks.skipped_time is
    '"Omitida" (no me la tome): sale de la vista pero registra que NO se hizo. Excluyente con completed_time.';

-- -----------------------------------------------------------------------------
-- checklist_items -- subtareas de una tarea
-- -----------------------------------------------------------------------------
create table checklist_items (
    id             uuid primary key default gen_random_uuid(),
    task_id        uuid not null references tasks (id) on delete cascade,
    title          text not null,
    status         smallint not null default 0,
    completed_time timestamptz,
    is_all_day     boolean not null default false,
    start_date     timestamptz,
    time_zone      text,
    sort_order     bigint not null default 0,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now(),

    constraint checklist_items_status_chk check (status in (0, 1))
);

create index idx_checklist_items_task_id on checklist_items (task_id);

-- -----------------------------------------------------------------------------
-- tags + task_tags -- etiquetas (N:M)
-- -----------------------------------------------------------------------------
create table tags (
    id         uuid primary key default gen_random_uuid(),
    name       text not null,
    color      text,
    sort_order bigint not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint tags_name_uk unique (name)
);

create table task_tags (
    task_id uuid not null references tasks (id) on delete cascade,
    tag_id  uuid not null references tags (id) on delete cascade,
    primary key (task_id, tag_id)
);

create index idx_task_tags_tag_id on task_tags (tag_id);


-- =============================================================================
-- Triggers de updated_at -- todas las tablas menos task_tags, que es una tabla
-- puente sin columnas de auditoria.
-- =============================================================================
create trigger trg_project_groups_updated  before update on project_groups  for each row execute function set_updated_at();
create trigger trg_projects_updated        before update on projects        for each row execute function set_updated_at();
create trigger trg_statuses_updated        before update on statuses        for each row execute function set_updated_at();
create trigger trg_habit_sections_updated  before update on habit_sections  for each row execute function set_updated_at();
create trigger trg_habits_updated          before update on habits          for each row execute function set_updated_at();
create trigger trg_habit_checkins_updated  before update on habit_checkins  for each row execute function set_updated_at();
create trigger trg_task_templates_updated  before update on task_templates  for each row execute function set_updated_at();
create trigger trg_tasks_updated           before update on tasks           for each row execute function set_updated_at();
create trigger trg_checklist_items_updated before update on checklist_items for each row execute function set_updated_at();
create trigger trg_tags_updated            before update on tags            for each row execute function set_updated_at();
