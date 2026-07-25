-- =============================================================================
-- 20260724120300_rls_contract
--
-- Lo que convierte el contrato en OBLIGATORIO en vez de en una sugerencia.
--
-- Sin esto, cualquier cliente con la clave anon puede saltarse las vistas y las
-- funciones y escribir directo en las tablas. Con esto, no puede: la clave anon
-- solo sirve para leer las vistas y llamar a las funciones.
--
-- Contexto: la base esta en Supabase cloud, con URL publica. La clave anon vive
-- en texto plano en el .env de una Raspberry Pi y vivira en el JS de una PWA.
-- Hay que asumirla comprometida y limitar lo que permite.
--
-- NOTA IMPORTANTE sobre las vistas: en Postgres una vista se ejecuta con los
-- permisos de SU PROPIETARIO salvo que lleve `security_invoker = true`. Como
-- estas vistas las crea el rol de migracion, atraviesan el RLS de las tablas
-- subyacentes. Eso es exactamente lo que queremos: anon lee la vista, no la
-- tabla. VERIFICA que funciona antes de darlo por bueno (ver README).
-- =============================================================================

-- 1. RLS activado y sin ninguna politica -> nadie pasa por la puerta principal.
alter table habits          enable row level security;
alter table habit_checkins  enable row level security;
alter table habit_sections  enable row level security;
alter table tasks           enable row level security;
alter table checklist_items enable row level security;
alter table projects        enable row level security;
alter table project_groups  enable row level security;
alter table statuses        enable row level security;
alter table tags            enable row level security;
alter table task_tags       enable row level security;

-- 2. Revocar lo que Supabase concede por defecto a anon/authenticated.
--    Sin este paso, RLS estaria activo pero los GRANT seguirian ahi.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;

-- 3. Conceder EXCLUSIVAMENTE el contrato.
grant usage on schema public to anon;

grant select on v_today_habits to anon;
grant select on v_today_tasks  to anon;

grant execute on function app_today()                                   to anon;
grant execute on function habit_step(uuid)                              to anon;
grant execute on function habit_set(uuid, double precision)             to anon;
grant execute on function habit_undo(uuid)                              to anon;
grant execute on function complete_task(uuid)                           to anon;
grant execute on function uncomplete_task(uuid)                         to anon;

-- 4. Que las tablas futuras no aparezcan abiertas por defecto.
alter default privileges in schema public
    revoke all on tables from anon, authenticated;
