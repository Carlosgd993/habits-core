-- =============================================================================
-- 20260727120000_schedule_columns
--
-- Los TIPOS de habitos y tareas, modelados como dos ejes ortogonales:
--   - QUE mides   -> habits.type (Boolean/Real), ya existia.
--   - CUANDO toca -> schedule_type + parametros (esta migracion).
--
-- Ademas:
--   - habits.purpose ('goal'/'log'): un 'log' (p.ej. "bebi cocacola") nunca
--     sale como pendiente; solo registra. Vive en habits para no partir el
--     pipeline de checkins ni la analitica.
--   - task_templates: la definicion reutilizable. tasks pasa a ser OCURRENCIAS.
--   - tasks.skipped_time: tercer estado terminal "omitida" (no me la tome),
--     distinto de "hecha": sale de la vista pero registra que NO se hizo.
--
-- Se ELIMINA `repeat_rule` (texto RRULE) de habits y tasks: quedaba muerto,
-- la recurrencia vive ahora en schedule_type + task_templates.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- HABITOS: purpose + programacion
-- -----------------------------------------------------------------------------
alter table habits
    add column if not exists purpose       text    not null default 'goal',
    add column if not exists schedule_type text,
    add column if not exists interval_n    integer not null default 1,
    add column if not exists byday         smallint[] not null default '{}',
    add column if not exists bymonthday    smallint,
    add column if not exists anchor_date   date;

-- Backfill: todo habito existente era, de hecho, diario. Se le asigna
-- interval_calendar con intervalo 1 y un ancla (target_start_date si la tenia,
-- si no hoy). Asi la CHECK de mas abajo se cumple sin bloquear filas viejas.
update habits
   set schedule_type = 'interval_calendar'
 where schedule_type is null
   and purpose = 'goal';

update habits
   set anchor_date = coalesce(anchor_date, target_start_date, app_today())
 where schedule_type = 'interval_calendar'
   and anchor_date is null;

-- Restricciones (idempotentes via guardas: una migracion se aplica una vez,
-- pero esto tolera un re-apply parcial sin petar con "already exists").
do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'habits_purpose_chk') then
        alter table habits add constraint habits_purpose_chk
            check (purpose in ('goal', 'log'));
    end if;
    if not exists (select 1 from pg_constraint where conname = 'habits_schedule_type_chk') then
        alter table habits add constraint habits_schedule_type_chk
            check (schedule_type is null or schedule_type in
                   ('interval_calendar', 'weekly_days', 'weekly_quota', 'monthly_day'));
    end if;
    if not exists (select 1 from pg_constraint where conname = 'habits_interval_n_chk') then
        alter table habits add constraint habits_interval_n_chk
            check (interval_n >= 1);
    end if;
    if not exists (select 1 from pg_constraint where conname = 'habits_bymonthday_chk') then
        alter table habits add constraint habits_bymonthday_chk
            check (bymonthday is null or bymonthday between 1 and 31);
    end if;
    -- Un habito 'goal' DEBE tener programacion; un 'log' la ignora.
    if not exists (select 1 from pg_constraint where conname = 'habits_goal_needs_schedule_chk') then
        alter table habits add constraint habits_goal_needs_schedule_chk
            check (purpose = 'log' or schedule_type is not null);
    end if;
end $$;

comment on column habits.purpose is
    '''goal'' = habito con objetivo, sale en v_today_habits los dias que toca. '
    '''log'' = solo registro (p.ej. "bebi cocacola"), nunca pendiente; sale en v_log_habits.';
comment on column habits.schedule_type is
    'interval_calendar (n dias desde anchor_date; n=1 = diario) | weekly_days (byday, isodow 1..7) '
    '| weekly_quota (goal = veces por semana, cualquier dia) | monthly_day (bymonthday).';
comment on column habits.byday is 'weekly_days: dias ISO (1=lunes .. 7=domingo).';

-- El texto RRULE queda obsoleto: la recurrencia vive en schedule_type + params.
alter table habits drop column if exists repeat_rule;

-- -----------------------------------------------------------------------------
-- TASK_TEMPLATES: la definicion reutilizable
--
-- Una plantilla NO tiene due_date ni completed_time (eso es de la ocurrencia).
-- `subtasks` es un array JSON de objetos {"title": "...", "sort_order": n};
-- instantiate_task los copia a checklist_items de la ocurrencia nueva.
-- `times_of_day` sirve para materializar VARIAS ocurrencias el mismo dia
-- (pastilla 09:00/14:00/21:00) sin inventar un schedule_type intradia.
-- -----------------------------------------------------------------------------
create table if not exists task_templates (
    id            uuid primary key default gen_random_uuid(),
    title         text not null,
    project_id    uuid references projects (id) on delete set null,
    priority      smallint not null default 0 check (priority in (0, 1, 3, 5)),
    subtasks      jsonb not null default '[]',
    schedule_type text not null default 'none'
        check (schedule_type in ('interval_calendar', 'interval_completion', 'monthly_day', 'none')),
    interval_n    integer not null default 1 check (interval_n >= 1),
    bymonthday    smallint check (bymonthday is null or bymonthday between 1 and 31),
    times_of_day  time[] not null default '{}',
    anchor_date   date,
    active        boolean not null default true,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

create index if not exists idx_task_templates_active on task_templates (active);

create or replace trigger trg_task_templates_updated
    before update on task_templates for each row execute function set_updated_at();

comment on table task_templates is
    'Definicion reutilizable de una tarea. Las ocurrencias concretas viven en tasks. '
    'schedule_type: interval_calendar (fija, materializa pg_cron) | interval_completion '
    '(deslizante, la crea complete_task) | monthly_day | none (manual / repetible sin tiempo).';
comment on column task_templates.subtasks is
    'Array JSON de subtareas: [{"title": "...", "sort_order": 0}, ...]. Se copian al instanciar.';
comment on column task_templates.times_of_day is
    'Horas fijas para materializar varias ocurrencias el mismo dia (p.ej. pastilla 09/14/21).';

-- -----------------------------------------------------------------------------
-- TASKS: enlace a plantilla + estado "omitida"
-- -----------------------------------------------------------------------------
alter table tasks
    add column if not exists template_id  uuid references task_templates (id) on delete set null,
    add column if not exists skipped_time timestamptz;

create index if not exists idx_tasks_template_id on tasks (template_id);

do $$
begin
    -- Una ocurrencia no puede estar a la vez hecha y omitida.
    if not exists (select 1 from pg_constraint where conname = 'tasks_done_xor_skip_chk') then
        alter table tasks add constraint tasks_done_xor_skip_chk
            check (completed_time is null or skipped_time is null);
    end if;
end $$;

comment on column tasks.template_id is
    'Plantilla de la que nace la ocurrencia. NULL = tarea unica (sin plantilla).';
comment on column tasks.skipped_time is
    '"Omitida" (no me la tome): sale de la vista pero registra que NO se hizo. Excluyente con completed_time.';

-- El texto RRULE queda obsoleto: la recurrencia vive en task_templates.
alter table tasks drop column if exists repeat_rule;
