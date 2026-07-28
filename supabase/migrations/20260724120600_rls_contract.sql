-- =============================================================================
-- 20260724120600_rls_contract
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
-- ESTE FICHERO VA SIEMPRE EL ULTIMO: revoca sobre "all tables / functions in
-- schema public", asi que todas las tablas, vistas y funciones tienen que
-- existir ya cuando se ejecuta. Si anades objetos nuevos despues, o los anades
-- a los grants de aqui, o quedaran cerrados (que es el fallo seguro correcto).
--
-- NOTA sobre las vistas: en Postgres una vista se ejecuta con los permisos de
-- SU PROPIETARIO salvo que lleve `security_invoker = true`. Como estas vistas
-- las crea el rol de migracion, atraviesan el RLS de las tablas subyacentes.
-- Eso es exactamente lo que queremos: anon lee la vista, no la tabla. VERIFICA
-- que funciona antes de darlo por bueno (ver README).
--
-- EL LINTER DE SUPABASE SE VA A QUEJAR DE ESO, y hay que ignorarlo a sabiendas:
-- `supabase db advisors` marca las 4 vistas con `security_definer_view`. La
-- alerta esta pensada para apps multi-usuario, donde una vista sin
-- `security_invoker` filtra filas de otros usuarios. Aqui no hay usuarios: la
-- base es mono-usuario y la vista ES el mecanismo de acceso. Poner
-- `security_invoker = true` para "arreglar" el aviso deja las cuatro vistas
-- devolviendo cero filas, sin ningun error -- exactamente el fallo silencioso
-- que la regla de compatibilidad intenta evitar.
--
-- NOTA sobre el Data API: desde el cambio de Supabase de 2026-04-28, las tablas
-- y vistas nuevas de `public` YA NO se exponen solas en /rest/v1. Los `grant`
-- explicitos de aqui abajo no son solo el minimo privilegio: son tambien lo que
-- da de alta cada vista en el Data API. Si una vista responde 404, mira primero
-- que tenga su `grant select ... to anon` en el bloque 3.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. RLS activado y sin ninguna politica -> nadie pasa por la puerta principal.
-- -----------------------------------------------------------------------------
alter table project_groups  enable row level security;
alter table projects        enable row level security;
alter table statuses        enable row level security;
alter table habit_sections  enable row level security;
alter table habits          enable row level security;
alter table habit_checkins  enable row level security;
alter table task_templates  enable row level security;
alter table tasks           enable row level security;
alter table checklist_items enable row level security;
alter table tags            enable row level security;
alter table task_tags       enable row level security;

-- -----------------------------------------------------------------------------
-- 2. Revocar lo que se concede por defecto.
--    Sin este paso, RLS estaria activo pero los GRANT seguirian ahi.
--
--    Ojo: hay DOS fuentes de permisos por defecto, y revocar solo una no sirve
--    de nada.
--
--    a) Los GRANT de Supabase a anon/authenticated sobre tablas y secuencias.
--    b) El `EXECUTE ON FUNCTIONS TO PUBLIC` que concede POSTGRES, no Supabase,
--       a cada funcion nueva. `anon` hereda de PUBLIC, asi que revocar de
--       `anon` NO se lo quita: cada funcion de `public` sigue siendo un
--       endpoint /rest/v1/rpc/<nombre> llamable con la clave publica. Eso
--       incluye las internas -- `chain_next_occurrence(uuid)` crearia
--       ocurrencias a peticion de cualquiera con la clave.
--
--    Por eso se revoca de PUBLIC y luego se devuelve el EXECUTE a las funciones
--    del contrato, una por una, en el bloque 3.
--
--    `service_role` (la clave de servicio) se restituye entero porque es el rol
--    administrativo y no tiene sentido cerrarle las internas de mantenimiento;
--    revocar de PUBLIC se lo habria quitado de rebote. Los triggers de
--    `set_updated_at()` no dependen de esto: Postgres comprueba el EXECUTE de
--    una funcion de trigger al hacer CREATE TRIGGER, no cada vez que dispara.
-- -----------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;
revoke execute on all functions in schema public from public;

grant execute on all functions in schema public to service_role;

-- -----------------------------------------------------------------------------
-- 3. Conceder EXCLUSIVAMENTE el contrato.
-- -----------------------------------------------------------------------------
grant usage on schema public to anon;

-- Lectura: solo vistas.
grant select on v_today_habits to anon;
grant select on v_log_habits   to anon;
grant select on v_today_tasks  to anon;
grant select on v_templates    to anon;

-- Escritura: solo funciones.
--
-- app_timezone() necesita su propio grant aunque ningun cliente la llame
-- directamente: app_today() la invoca por dentro, y al ser ambas `security
-- invoker` el EXECUTE se comprueba contra anon. Sin este grant, las vistas que
-- usan la fecha fallan con "permission denied for function app_timezone".
grant execute on function app_timezone()                            to anon;
grant execute on function app_today()                               to anon;
grant execute on function habit_step(uuid)                          to anon;
grant execute on function habit_set(uuid, double precision)         to anon;
grant execute on function habit_undo(uuid)                          to anon;
grant execute on function instantiate_task(uuid, timestamptz)       to anon;
grant execute on function complete_task(uuid)                       to anon;
grant execute on function uncomplete_task(uuid)                     to anon;
grant execute on function skip_task(uuid)                           to anon;
grant execute on function unskip_task(uuid)                         to anon;

-- -----------------------------------------------------------------------------
-- 4. Que los objetos FUTUROS no aparezcan abiertos por defecto.
--
-- Lo de arriba solo actua sobre lo que ya existe. Esto hace que una tabla o una
-- funcion creada manana nazca cerrada, sin tener que acordarse de revocarla.
--
-- Limitacion que conviene saber: `alter default privileges` sin `for role` solo
-- afecta a los objetos que cree ESTE rol. Si algun dia se crea algo con otro
-- rol, esto no lo cubre -- para las tablas la red de seguridad es el event
-- trigger de la migracion siguiente; para las funciones, no hay red: hay que
-- revisarlo a mano.
-- -----------------------------------------------------------------------------
alter default privileges in schema public
    revoke all on tables from anon, authenticated;

alter default privileges in schema public
    revoke all on sequences from anon, authenticated;

alter default privileges in schema public
    revoke execute on functions from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- La red de seguridad para tablas FUTURAS (event trigger rls_auto_enable) esta
-- deliberadamente en la migracion siguiente y no aqui: `create event trigger`
-- exige superusuario y puede no estar permitido segun el plan/rol de Supabase.
-- Si estuviera en este fichero y fallara, el CLI haria rollback de TODA la
-- migracion -- incluidos los grants de arriba -- y te quedarias con el esquema
-- entero y `anon` sin un solo permiso: todos los clientes a 401 por una causa
-- nada evidente. Separado, el contrato commitea y el fallo queda aislado.
-- -----------------------------------------------------------------------------
