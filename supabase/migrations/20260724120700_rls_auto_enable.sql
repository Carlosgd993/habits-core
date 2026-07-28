-- =============================================================================
-- 20260724120700_rls_auto_enable
--
-- Red de seguridad permanente: activar RLS automaticamente en CUALQUIER tabla
-- futura del esquema public.
--
-- La migracion anterior solo cubre las tablas que existen hoy. Este event
-- trigger cubre las de manana: crear una tabla la deja con RLS activado y sin
-- politicas -> cerrada por defecto. Los `grant` siguen siendo explicitos.
--
-- Existe porque ya paso una vez: `task_templates` se creo en su dia despues del
-- fichero de RLS y quedo abierta a `anon`.
--
-- -----------------------------------------------------------------------------
-- POR QUE ESTA SOLA EN SU PROPIO FICHERO
--
-- `create event trigger` exige SUPERUSUARIO. El rol con el que Supabase aplica
-- las migraciones (`postgres`) no siempre lo es, asi que esta sentencia puede
-- fallar con "permission denied to create event trigger" segun el proyecto.
--
-- El CLI envuelve cada fichero de migracion en una transaccion. Si esto viviera
-- al final de `..._rls_contract.sql`, un fallo aqui haria rollback de aquella
-- migracion COMPLETA -- grants incluidos -- y el resultado seria el esquema
-- entero creado con `anon` sin un solo permiso: todos los clientes a 401, y con
-- una causa raiz nada evidente.
--
-- Aislada, el contrato de la migracion anterior queda commiteado y este fallo
-- (si ocurre) es un fallo claro, localizado y no bloqueante.
--
-- SI ESTA MIGRACION FALLA: no es critico. Solo pierdes el automatismo; las
-- tablas de hoy ya tienen RLS por el paso 1 de `..._rls_contract.sql`. Lo que
-- pasa a ser tu responsabilidad es acordarte de hacer `alter table ... enable
-- row level security` a mano en cada tabla nueva.
-- =============================================================================

-- `security invoker` a proposito: se ejecuta con el rol que crea la tabla, que
-- por ser su propietario ya puede activarle RLS. No hace falta `definer` -- y
-- ponerlo seria darle superusuario a algo que ejecuta DDL con `format()`.
-- El `set search_path` si va, porque justamente ejecuta SQL dinamico.
create or replace function rls_auto_enable()
    returns event_trigger
    language plpgsql
    set search_path = public
as $$
declare
    obj record;
begin
    for obj in
        select * from pg_event_trigger_ddl_commands()
        where command_tag = 'CREATE TABLE'
          and schema_name = 'public'
    loop
        execute format('alter table %s enable row level security', obj.object_identity);
    end loop;
end;
$$;

create event trigger trg_rls_auto_enable
    on ddl_command_end
    when tag in ('CREATE TABLE')
    execute function rls_auto_enable();

comment on function rls_auto_enable() is
    'Event trigger: activa RLS en toda tabla nueva de public. Red de seguridad '
    'para que ninguna tabla quede abierta por olvido.';
