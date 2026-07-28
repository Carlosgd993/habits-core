-- =============================================================================
-- seed.sql -- datos de PRUEBA para el proyecto de test (rama `test`)
--
-- Un habito y una tarea de CADA tipo, para verificar las vistas y las RPC
-- contra datos reales (una base vacia devuelve 0 filas y no prueba nada).
--
-- Idempotente: UUIDs fijos + ON CONFLICT DO NOTHING, se puede re-ejecutar.
-- NO ejecutar contra produccion: crea datos de ejemplo.
--
-- Ejecutar sobre el proyecto de test, p.ej.:
--   psql "$TEST_DB_URL" -f supabase/seed.sql
-- (o el runner de seed que uses). Requiere las migraciones ya aplicadas.
-- =============================================================================

-- --- Catalogo minimo -------------------------------------------------------
insert into habit_sections (id, name, sort_order) values
    ('aaaa0000-0000-0000-0000-000000000001', 'Salud', 0)
on conflict (id) do nothing;

insert into projects (id, name, color, view_mode, kind) values
    ('bbbb0000-0000-0000-0000-000000000001', 'Personal', '#4D8CF5', 'list', 'TASK')
on conflict (id) do nothing;

-- =============================================================================
-- HABITOS -- uno de cada tipo
-- =============================================================================

-- 1. Boolean diario (interval_calendar, n=1)
insert into habits (id, name, icon_res, type, goal, step, unit, purpose,
                    schedule_type, interval_n, anchor_date, section_id, sort_order)
values ('c0000000-0000-0000-0000-000000000001', 'Leer', 'txt_📖', 'Boolean', 1, 1, 'Count',
        'goal', 'interval_calendar', 1, app_today(),
        'aaaa0000-0000-0000-0000-000000000001', 1)
on conflict (id) do nothing;

-- 2. Real diario incremental, sin tope (10/8 valido)
insert into habits (id, name, icon_res, type, goal, step, unit, purpose,
                    schedule_type, interval_n, anchor_date, record_enable, section_id, sort_order)
values ('c0000000-0000-0000-0000-000000000002', 'Flexiones', 'txt_💪', 'Real', 100, 5, 'Reps',
        'goal', 'interval_calendar', 1, app_today(), true,
        'aaaa0000-0000-0000-0000-000000000001', 2)
on conflict (id) do nothing;

-- 3. Dias laborales (weekly_days: L,M,X,J,V = isodow 1..5)
insert into habits (id, name, icon_res, type, goal, purpose,
                    schedule_type, byday, section_id, sort_order)
values ('c0000000-0000-0000-0000-000000000003', 'Estudiar', 'txt_📚', 'Boolean', 1,
        'goal', 'weekly_days', '{1,2,3,4,5}',
        'aaaa0000-0000-0000-0000-000000000001', 3)
on conflict (id) do nothing;

-- 4. Cuota semanal (weekly_quota: 3 veces/semana, cualquier dia; goal = 3)
insert into habits (id, name, icon_res, type, goal, purpose,
                    schedule_type, section_id, sort_order)
values ('c0000000-0000-0000-0000-000000000004', 'Gimnasio', 'txt_🏋️', 'Boolean', 3,
        'goal', 'weekly_quota',
        'aaaa0000-0000-0000-0000-000000000001', 4)
on conflict (id) do nothing;

-- 5. Dia fijo del mes (monthly_day: el dia 1)
insert into habits (id, name, icon_res, type, goal, purpose,
                    schedule_type, bymonthday, section_id, sort_order)
values ('c0000000-0000-0000-0000-000000000005', 'Revisar finanzas', 'txt_💰', 'Boolean', 1,
        'goal', 'monthly_day', 1,
        'aaaa0000-0000-0000-0000-000000000001', 5)
on conflict (id) do nothing;

-- 6. Solo registro (purpose=log): no aparece en v_today_habits, si en v_log_habits
insert into habits (id, name, icon_res, type, purpose, section_id, sort_order)
values ('c0000000-0000-0000-0000-000000000006', 'Bebi cocacola', 'txt_🥤', 'Boolean',
        'log', 'aaaa0000-0000-0000-0000-000000000001', 6)
on conflict (id) do nothing;

-- =============================================================================
-- TAREAS -- una de cada tipo
--
-- Las plantillas definen la recurrencia; las ocurrencias (tasks) son lo que se
-- ve y se completa. Aqui se insertan ocurrencias a mano (con due_date de hoy)
-- para que v_today_tasks muestre datos SIN depender del materializador pg_cron,
-- que aun no existe.
-- =============================================================================

-- A. Recurrente FIJA (interval_calendar, cada 3 dias) --------------------------
insert into task_templates (id, title, project_id, priority, schedule_type, interval_n, anchor_date)
values ('d0000000-0000-0000-0000-00000000000a', 'Sacar la basura',
        'bbbb0000-0000-0000-0000-000000000001', 1, 'interval_calendar', 3, app_today())
on conflict (id) do nothing;

insert into tasks (id, project_id, template_id, title, priority, due_date)
values ('e0000000-0000-0000-0000-00000000000a', 'bbbb0000-0000-0000-0000-000000000001',
        'd0000000-0000-0000-0000-00000000000a', 'Sacar la basura', 1,
        date_trunc('day', now()) + interval '20 hour')
on conflict (id) do nothing;

-- B. Recurrente DESLIZANTE (interval_completion, 3 dias tras completar) --------
insert into task_templates (id, title, project_id, priority, subtasks, schedule_type, interval_n)
values ('d0000000-0000-0000-0000-00000000000b', 'Regar las plantas',
        'bbbb0000-0000-0000-0000-000000000001', 1,
        '[{"title": "Salon", "sort_order": 0}, {"title": "Balcon", "sort_order": 1}]',
        'interval_completion', 3)
on conflict (id) do nothing;

insert into tasks (id, project_id, template_id, title, priority, due_date)
values ('e0000000-0000-0000-0000-00000000000b', 'bbbb0000-0000-0000-0000-000000000001',
        'd0000000-0000-0000-0000-00000000000b', 'Regar las plantas', 1,
        date_trunc('day', now()) + interval '10 hour')
on conflict (id) do nothing;

-- C. Repetible SIN TIEMPO (none, se instancia a demanda) -----------------------
insert into task_templates (id, title, project_id, priority, subtasks, schedule_type)
values ('d0000000-0000-0000-0000-00000000000c', 'Cambiar las sabanas',
        'bbbb0000-0000-0000-0000-000000000001', 0,
        '[{"title": "Quitar sabanas", "sort_order": 0}, {"title": "Poner limpias", "sort_order": 1}]',
        'none')
on conflict (id) do nothing;

insert into tasks (id, project_id, template_id, title, priority, due_date)
values ('e0000000-0000-0000-0000-00000000000c', 'bbbb0000-0000-0000-0000-000000000001',
        'd0000000-0000-0000-0000-00000000000c', 'Cambiar las sabanas', 0,
        date_trunc('day', now()) + interval '12 hour')
on conflict (id) do nothing;

-- D. Horas fijas del dia (times_of_day: pastilla 09/14/21) ---------------------
insert into task_templates (id, title, project_id, priority, schedule_type, interval_n, times_of_day)
values ('d0000000-0000-0000-0000-00000000000d', 'Tomar pastilla',
        'bbbb0000-0000-0000-0000-000000000001', 3, 'interval_calendar', 1,
        '{09:00, 14:00, 21:00}')
on conflict (id) do nothing;

insert into tasks (id, project_id, template_id, title, priority, due_date) values
    ('e0000000-0000-0000-0000-00000000d001', 'bbbb0000-0000-0000-0000-000000000001',
     'd0000000-0000-0000-0000-00000000000d', 'Tomar pastilla', 3,
     date_trunc('day', now()) + interval '9 hour'),
    ('e0000000-0000-0000-0000-00000000d002', 'bbbb0000-0000-0000-0000-000000000001',
     'd0000000-0000-0000-0000-00000000000d', 'Tomar pastilla', 3,
     date_trunc('day', now()) + interval '14 hour'),
    ('e0000000-0000-0000-0000-00000000d003', 'bbbb0000-0000-0000-0000-000000000001',
     'd0000000-0000-0000-0000-00000000000d', 'Tomar pastilla', 3,
     date_trunc('day', now()) + interval '21 hour')
on conflict (id) do nothing;

-- E. Tarea UNICA (sin plantilla, template_id NULL). Vencida ayer -> overdue -----
insert into tasks (id, project_id, template_id, title, priority, due_date)
values ('e0000000-0000-0000-0000-00000000000e', 'bbbb0000-0000-0000-0000-000000000001',
        null, 'Llamar al dentista', 5,
        date_trunc('day', now()) - interval '4 hour')
on conflict (id) do nothing;

-- =============================================================================
-- Comprobaciones rapidas tras sembrar (descomentar para inspeccionar):
--   select name, schedule_type, current_value, goal, done from v_today_habits order by sort_order;
--     -> NO debe salir "Bebi cocacola" (es log). "Estudiar" solo sale L-V.
--        "Revisar finanzas" solo sale el dia 1. "Gimnasio" sale siempre (0/3).
--   select name from v_log_habits;              -> solo "Bebi cocacola".
--   select title, overdue from v_today_tasks order by due_date;
--     -> "Llamar al dentista" con overdue=true; el resto de hoy.
--   select complete_task('e0000000-0000-0000-0000-00000000000b');  -- regar plantas
--   select title, due_date from tasks where template_id = 'd0000000-0000-0000-0000-00000000000b';
--     -> debe aparecer una ocurrencia NUEVA a 3 dias vista (deslizante).
--   select skip_task('<id de la ocurrencia nueva>');
--     -> omitir encadena IGUAL que completar: aparece otra a 3 dias vista, y la
--        omitida queda con skipped_time (no completed_time) y sin status_id.
--   update task_templates set active = false where id = 'd0000000-0000-0000-0000-00000000000b';
--   select complete_task('<id de la ultima ocurrencia>');
--     -> debe cerrarse SIN error y SIN crear otra: desactivar para la cadena.
-- =============================================================================
