-- =============================================================================
-- 20260727120100_schedule_views_rpc
--
-- El contrato, actualizado a los tipos de programacion:
--   - v_today_habits reescrita: filtra por "toca hoy" segun schedule_type, y
--     para weekly_quota cuenta los dias de ESTA semana en vez del valor de hoy.
--   - v_log_habits (nueva): habitos de solo registro (purpose='log').
--   - v_today_tasks reescrita: excluye tambien las omitidas (skipped_time).
--   - habit_step actualizada: en weekly_quota, cada dia suma 1 (un dia de gym),
--     no salta a goal.
--   - instantiate_task / complete_task (con enganche deslizante) / skip_task /
--     unskip_task: el ciclo de vida de las ocurrencias.
--
-- Las vistas NO llevan security_invoker: se ejecutan con permisos del
-- propietario y atraviesan el RLS de las tablas. Los clientes leen la vista.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- v_today_habits -- habitos con objetivo que TOCAN hoy
--
-- "Toca hoy" depende del schedule_type:
--   interval_calendar : (hoy - anchor) es multiplo de interval_n
--   weekly_days       : hoy (isodow) esta en byday
--   weekly_quota      : SIEMPRE se muestra (cualquier dia cuenta)
--   monthly_day       : dia del mes = bymonthday
--
-- current_value tambien depende del tipo:
--   weekly_quota : nº de dias con checkin en la semana ISO actual (2/3)
--   resto        : valor del checkin de hoy (puede superar goal: 10/8 valido)
-- -----------------------------------------------------------------------------
create or replace view v_today_habits as
with wk as (
    select date_trunc('week', app_today())::date as week_start  -- lunes ISO
),
base as (
    select h.id, h.name, h.icon_res, h.color, h.type, h.goal, h.step, h.unit,
           h.sort_order, h.section_id,
           case
               when h.schedule_type = 'weekly_quota'
                   then (select count(*)::double precision
                           from habit_checkins c, wk
                          where c.habit_id = h.id
                            and c.checkin_date >= wk.week_start
                            and c.checkin_date <  wk.week_start + 7
                            and c.value > 0)
               else coalesce((select c.value
                                from habit_checkins c
                               where c.habit_id = h.id
                                 and c.checkin_date = app_today()), 0)
           end as current_value,
           case h.schedule_type
               when 'interval_calendar'
                   then h.anchor_date is not null
                        and ((app_today() - h.anchor_date) % h.interval_n) = 0
               when 'weekly_days'
                   then extract(isodow from app_today())::smallint = any (h.byday)
               when 'weekly_quota'
                   then true
               when 'monthly_day'
                   then extract(day from app_today())::smallint = h.bymonthday
               else false
           end as is_due
      from habits h
     where h.status = 0
       and h.purpose = 'goal'
)
select id, name, icon_res, color, type, goal, step, unit, sort_order, section_id,
       current_value,
       current_value >= goal as done,
       app_today()           as day
  from base
 where is_due;

comment on view v_today_habits is
    'Habitos con objetivo que tocan hoy segun su schedule_type, con el progreso de hoy '
    '(o de la semana, en weekly_quota). No arrastran deuda.';

-- -----------------------------------------------------------------------------
-- v_log_habits -- habitos de solo registro (no son "pendientes")
--
-- No tienen objetivo ni programacion: nunca salen en v_today_habits. Existen
-- para poder pulsar un check ("bebi cocacola hoy") y consultarlos luego.
-- -----------------------------------------------------------------------------
create or replace view v_log_habits as
select h.id, h.name, h.icon_res, h.color, h.type, h.unit, h.sort_order, h.section_id,
       coalesce((select c.value
                   from habit_checkins c
                  where c.habit_id = h.id
                    and c.checkin_date = app_today()), 0) as current_value,
       app_today() as day
  from habits h
 where h.status = 0
   and h.purpose = 'log';

comment on view v_log_habits is
    'Habitos de solo registro (purpose=log). Nunca son pendientes; se pulsan para dejar rastro.';

-- -----------------------------------------------------------------------------
-- v_today_tasks -- ocurrencias pendientes de hoy o antes
--
-- Anade el filtro de "omitida": una tarea con skipped_time no vuelve a salir.
-- Se anade template_id como columna (aditivo, no rompe clientes).
-- -----------------------------------------------------------------------------
create or replace view v_today_tasks as
select t.id, t.title, t.priority, t.project_id, t.sort_order, t.due_date, t.template_id,
       (t.due_date at time zone coalesce(t.time_zone, app_timezone()))::date as due_day,
       (t.due_date at time zone coalesce(t.time_zone, app_timezone()))::date < app_today()
                                                                             as overdue,
       app_today()                                                          as day
  from tasks t
 where t.completed_time is null
   and t.skipped_time is null
   and t.due_date is not null
   and (t.due_date at time zone coalesce(t.time_zone, app_timezone()))::date <= app_today();

comment on view v_today_tasks is
    'Ocurrencias pendientes (ni hechas ni omitidas) con vencimiento hoy o antes. Las vencidas arrastran.';

-- -----------------------------------------------------------------------------
-- habit_step -- ahora consciente de weekly_quota
--
-- weekly_quota: cada dia cuenta 1 (un dia de gym), idempotente en el dia.
-- Boolean normal: salta a goal.  Real: suma step sin tope.
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
-- complete_task -- cierra una ocurrencia, y si es deslizante crea la siguiente
--
-- Idempotente. Si la ocurrencia venia de una plantilla interval_completion,
-- crea la siguiente ocurrencia a interval_n dias DESDE AHORA (no del calendario).
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
    v_stype    text;
    v_interval integer;
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

    if v_template is not null then
        select schedule_type, interval_n into v_stype, v_interval
          from task_templates where id = v_template;
        if v_stype = 'interval_completion' then
            perform instantiate_task(v_template, now() + make_interval(days => v_interval));
        end if;
    end if;
end;
$$;

comment on function complete_task(uuid) is
    'Cierra una ocurrencia. Idempotente. Si la plantilla es deslizante, crea la siguiente.';

-- -----------------------------------------------------------------------------
-- skip_task / unskip_task -- "no me la tome" y su reverso
-- -----------------------------------------------------------------------------
create or replace function skip_task(p_task_id uuid)
    returns void
    language plpgsql
    security definer
    set search_path = public
as $$
begin
    update tasks
       set skipped_time = now()
     where id = p_task_id
       and completed_time is null
       and skipped_time is null;
end;
$$;

comment on function skip_task(uuid) is
    'Marca una ocurrencia como omitida (no se hizo). Sale de la vista pero queda registrada.';

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

-- -----------------------------------------------------------------------------
-- Grants: extender el contrato a los objetos nuevos.
-- (Las vistas/funciones reemplazadas con create or replace conservan sus grants;
--  se re-conceden por si acaso. Las nuevas necesitan grant explicito.)
-- -----------------------------------------------------------------------------
grant select on v_today_habits to anon;
grant select on v_log_habits   to anon;
grant select on v_today_tasks  to anon;

grant execute on function habit_step(uuid)                       to anon;
grant execute on function instantiate_task(uuid, timestamptz)    to anon;
grant execute on function complete_task(uuid)                    to anon;
grant execute on function skip_task(uuid)                        to anon;
grant execute on function unskip_task(uuid)                      to anon;
