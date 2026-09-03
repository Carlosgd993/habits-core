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
