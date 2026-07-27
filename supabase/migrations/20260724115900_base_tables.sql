-- =============================================================================
-- 20260724115900_base_tables
--
-- Las 10 tablas base del ecosistema. Hasta ahora vivian SOLO fuera de banda
-- (creadas a mano en el dashboard de Supabase / MCP) y documentadas -pero no
-- aplicadas- en docs/estructura-bd.md. Esta migracion las trae al repo.
--
-- Idempotente a proposito, porque tiene que comportarse distinto en cada sitio:
--   - En produccion, las tablas YA EXISTEN: todo aqui es un no-op (`if not
--     exists` / `create or replace`). No debe alterar una fila ni una columna.
--   - En un proyecto nuevo (p.ej. el de test), esta es la migracion que las
--     crea por primera vez, ANTES de que 20260724120000_time_and_status y las
--     siguientes empiecen a hacer `alter table` sobre ellas -- por eso el
--     timestamp es anterior a esa migracion, aunque se haya escrito despues.
--
-- El DDL replica exactamente docs/estructura-bd.md. Si alguna vez se detecta
-- que la produccion real diverge de este fichero (columna extra, tipo
-- distinto...), gana la base de datos real: corrige aqui y en el doc.
-- =============================================================================

create table if not exists project_groups (
    id         uuid primary key default gen_random_uuid(),
    name       text not null,
    sort_order bigint not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists projects (
    id         uuid primary key default gen_random_uuid(),
    name       text not null,
    color      text,
    sort_order bigint not null default 0,
    closed     boolean not null default false,
    group_id   uuid references project_groups (id) on delete set null,
    view_mode  text not null default 'list'
        check (view_mode in ('list', 'kanban', 'timeline')),
    kind       text not null default 'TASK'
        check (kind in ('TASK', 'NOTE')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists idx_projects_group_id on projects (group_id);

create table if not exists statuses (
    id         uuid primary key default gen_random_uuid(),
    name       text not null,
    color      text,
    sort_order bigint not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists tasks (
    id             uuid primary key default gen_random_uuid(),
    project_id     uuid not null references projects (id) on delete cascade,
    status_id      uuid references statuses (id) on delete set null,
    title          text not null,
    content        text,
    description    text,
    is_all_day     boolean not null default false,
    start_date     timestamptz,
    due_date       timestamptz,
    time_zone      text,
    repeat_rule    text,
    reminders      text[] not null default '{}',
    priority       smallint not null default 0 check (priority in (0, 1, 3, 5)),
    completed_time timestamptz,
    sort_order     bigint not null default 0,
    kind           text not null default 'TEXT'
        check (kind in ('TEXT', 'NOTE', 'CHECKLIST')),
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);

create index if not exists idx_tasks_project_id on tasks (project_id);
create index if not exists idx_tasks_status_id  on tasks (status_id);
create index if not exists idx_tasks_due_date    on tasks (due_date);

create table if not exists checklist_items (
    id             uuid primary key default gen_random_uuid(),
    task_id        uuid not null references tasks (id) on delete cascade,
    title          text not null,
    status         smallint not null default 0 check (status in (0, 1)),
    completed_time timestamptz,
    is_all_day     boolean not null default false,
    start_date     timestamptz,
    time_zone      text,
    sort_order     bigint not null default 0,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);

create index if not exists idx_checklist_items_task_id on checklist_items (task_id);

create table if not exists tags (
    id         uuid primary key default gen_random_uuid(),
    name       text not null unique,
    color      text,
    sort_order bigint not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists task_tags (
    task_id uuid not null references tasks (id) on delete cascade,
    tag_id  uuid not null references tags (id) on delete cascade,
    primary key (task_id, tag_id)
);

create index if not exists idx_task_tags_tag_id on task_tags (tag_id);

create table if not exists habit_sections (
    id         uuid primary key default gen_random_uuid(),
    name       text not null,
    sort_order bigint not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists habits (
    id                uuid primary key default gen_random_uuid(),
    name              text not null,
    icon_res          text,
    color             text,
    sort_order        bigint not null default 0,
    status            smallint not null default 0,
    encouragement     text,
    type              text not null default 'Boolean'
        check (type in ('Boolean', 'Real')),
    goal              double precision not null default 1,
    step              double precision not null default 1,
    unit              text,
    repeat_rule       text,
    reminders         text[] not null default '{}',
    record_enable     boolean not null default false,
    section_id        uuid references habit_sections (id) on delete set null,
    target_days       integer not null default 0,
    target_start_date date,
    completed_cycles  integer not null default 0,
    ex_dates          date[] not null default '{}',
    style             smallint not null default 0,
    archived_at       timestamptz,
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now()
);

create index if not exists idx_habits_section_id on habits (section_id);

create table if not exists habit_checkins (
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
    unique (habit_id, checkin_date)
);

create index if not exists idx_habit_checkins_habit_id on habit_checkins (habit_id);

-- -----------------------------------------------------------------------------
-- Trigger de updated_at. `create or replace trigger` (PG >= 14) para que sea
-- idempotente igual que las tablas: en produccion sustituye al trigger que ya
-- existia por uno identico; en un proyecto nuevo lo crea.
-- -----------------------------------------------------------------------------
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create or replace trigger trg_project_groups_updated  before update on project_groups  for each row execute function set_updated_at();
create or replace trigger trg_projects_updated        before update on projects        for each row execute function set_updated_at();
create or replace trigger trg_statuses_updated        before update on statuses        for each row execute function set_updated_at();
create or replace trigger trg_tasks_updated           before update on tasks           for each row execute function set_updated_at();
create or replace trigger trg_checklist_items_updated before update on checklist_items for each row execute function set_updated_at();
create or replace trigger trg_tags_updated            before update on tags            for each row execute function set_updated_at();
create or replace trigger trg_habit_sections_updated  before update on habit_sections  for each row execute function set_updated_at();
create or replace trigger trg_habits_updated          before update on habits          for each row execute function set_updated_at();
create or replace trigger trg_habit_checkins_updated  before update on habit_checkins  for each row execute function set_updated_at();
