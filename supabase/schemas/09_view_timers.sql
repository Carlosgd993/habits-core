-- =============================================================================
-- supabase/schemas/09_view_timers.sql
--
-- Definicion del ESTADO ACTUAL (no historia). Espejo de
-- supabase/migrations/<timestamp>_cronometros.sql.
--
-- El contrato de LECTURA de cronometros: que etiquetas rapidas ofrecer en el
-- deck (v_timer_labels) y cual esta corriendo ahora mismo, si lo hay
-- (v_running_timer). Ninguna vista expone timer_labels/time_entries
-- directamente: son la unica via de lectura, igual que v_templates lo es de
-- task_templates.
--
-- Si cambias algo aqui, cambia tambien la migration correspondiente en el
-- mismo commit -- no hay generacion automatica (no hay Supabase CLI instalado).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- v_timer_labels -- etiquetas rapidas activas
--
-- show_in_deck marca las de acceso rapido; el filtrado por esa columna es del
-- cliente (?show_in_deck=eq.true), igual que v_templates, asi un cliente
-- futuro sigue viendo el catalogo completo con el mismo grant.
-- -----------------------------------------------------------------------------
create or replace view v_timer_labels as
select l.id, l.name, l.color, l.sort_order, l.show_in_deck
  from timer_labels l
 where l.archived_at is null
 order by l.sort_order, l.name;

comment on view v_timer_labels is
    'Etiquetas de cronometro activas (no archivadas). show_in_deck marca las '
    'de acceso rapido -- filtrar en el cliente, igual que v_templates.show_in_deck.';

-- -----------------------------------------------------------------------------
-- v_running_timer -- el cronometro en marcha ahora mismo, si lo hay
--
-- 0 o 1 fila, garantizado por time_entries_single_running_idx. title ya viene
-- denormalizado: ningun cliente necesita cruzar con tasks ni timer_labels
-- para pintar "corriendo: <title>".
-- -----------------------------------------------------------------------------
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
-- v_timer_daily_totals -- tiempo acumulado HOY por tarea/etiqueta
--
-- Una fila por (task_id, label_id) con al menos una entrada hoy (dia de
-- app_timezone()), con la suma en segundos de todos sus bloques del dia. Si
-- el bloque sigue corriendo (stopped_at null) cuenta hasta este instante
-- (coalesce con now()) -- irrelevante en la practica para el cliente que
-- pinta el total (solo lo usa mientras la tarea/etiqueta esta PARADA, ver
-- contrato), pero mantiene el numero correcto si algo mas lo consulta
-- mientras corre.
--
-- Igual que v_running_timer: exactamente uno de los dos ids (o ninguno,
-- filtrado aqui) por el mismo check constraint de time_entries. El cliente
-- busca por el id de la tarea/etiqueta que este pintando, nunca al reves.
-- -----------------------------------------------------------------------------
create or replace view v_timer_daily_totals as
select te.task_id, te.label_id,
       sum(extract(epoch from (coalesce(te.stopped_at, now()) - te.started_at)))::bigint as seconds_today
  from time_entries te
 where (te.task_id is not null or te.label_id is not null)
   and (te.started_at at time zone app_timezone())::date = app_today()
 group by te.task_id, te.label_id;

comment on view v_timer_daily_totals is
    'Segundos acumulados hoy por tarea/etiqueta (una fila por cada una con '
    'al menos un bloque hoy). task_id/label_id son mutuamente excluyentes, '
    'igual que en v_running_timer. Un bloque que siga corriendo cuenta hasta '
    'ahora mismo (coalesce con now()).';
