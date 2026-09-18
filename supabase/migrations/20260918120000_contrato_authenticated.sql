-- =============================================================================
-- 20260918120000_contrato_authenticated
--
-- Abre el contrato -- el mismo, sin anadir ni quitar una pieza -- al rol
-- `authenticated`, ademas de a `anon`.
--
-- POR QUE
--
-- Hasta hoy el unico cliente era el daemon de la Stream Deck, que entra con la
-- clave publishable y por tanto como `anon`. La PWA (`../PWA`) entra con
-- Supabase Auth: en cuanto hay sesion, PostgREST resuelve el JWT y la peticion
-- corre como `authenticated`, no como `anon`. Y `authenticated` no tiene aqui
-- un solo permiso: el bloque 2 de `20260724120600_rls_contract.sql` le revoco
-- todo junto a `anon`, y el bloque 3 solo se lo devolvio a `anon`.
--
-- Sin esta migracion, iniciar sesion en la PWA no da un error de login: da
-- 404 en todas las vistas y 401 en todas las RPC. La sesion "funciona" y la
-- aplicacion entera esta muerta -- el fallo desconcertante de siempre, ahora
-- por rol en vez de por objeto.
--
-- QUE NO HACE: no revoca nada de `anon`. Es puramente aditivo, y por eso el
-- deck no se entera. Cerrar `anon` es el paso siguiente, y ese si obliga a
-- migrar antes el daemon a sesion autenticada -- con la Pi delante, no a
-- ciegas.
--
-- app_timezone() necesita su grant propio aunque ningun cliente la llame:
-- app_today() la invoca por dentro y ambas son `security invoker`, asi que el
-- EXECUTE se comprueba contra el rol que consulta. Sin el, las tres vistas que
-- usan la fecha fallan con "permission denied for function app_timezone". Ya
-- paso con `anon`; no vuelve a pasar por no copiar una linea.
-- =============================================================================

grant usage on schema public to authenticated;

-- Lectura: solo vistas, las ocho del contrato.
grant select on v_today_habits       to authenticated;
grant select on v_log_habits         to authenticated;
grant select on v_today_tasks        to authenticated;
grant select on v_templates          to authenticated;
grant select on v_timer_labels       to authenticated;
grant select on v_running_timer      to authenticated;
grant select on v_timer_daily_totals to authenticated;
grant select on v_task_timer_totals  to authenticated;

-- Escritura: solo funciones, las doce del contrato.
grant execute on function app_timezone()                        to authenticated;
grant execute on function app_today()                           to authenticated;
grant execute on function habit_step(uuid)                      to authenticated;
grant execute on function habit_set(uuid, double precision)     to authenticated;
grant execute on function habit_undo(uuid)                      to authenticated;
grant execute on function instantiate_task(uuid, timestamptz)   to authenticated;
grant execute on function complete_task(uuid)                   to authenticated;
grant execute on function uncomplete_task(uuid)                 to authenticated;
grant execute on function skip_task(uuid)                       to authenticated;
grant execute on function unskip_task(uuid)                     to authenticated;
grant execute on function set_task_priority(uuid, smallint)     to authenticated;
grant execute on function timer_toggle(uuid, uuid)              to authenticated;

-- Las tablas siguen cerradas para `authenticated` igual que para `anon`: el
-- `revoke all on all tables` y el `alter default privileges` del contrato ya
-- nombraban a los dos roles, y aqui no se toca ninguno de los dos. Una vista o
-- funcion nueva seguira naciendo cerrada para ambos y necesitando su grant
-- explicito -- ahora en dos lineas en vez de una.
