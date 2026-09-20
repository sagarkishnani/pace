-- ============================================================
-- Ciclos atípicos, y elegir el % de ahorro con números
--
-- Dos cosas que salieron de arrancar de verdad:
--
-- 1. Un ciclo puede ser real y aun así no ser comparable.
--    Setiembre 2026 fue eso: se saldaron deudas viejas (~10k de
--    tarjeta), el monto a la esposa todavía no estaba fijado y el
--    alquiler se pagó aparte. Los movimientos son ciertos y el
--    hábito de registrar vale, pero promediar ese mes contra uno
--    normal no dice nada. Se guarda, se ve, y no cuenta.
--
-- 2. `pct_ahorro` se elegía a ciegas. El número que importa no es
--    el porcentaje sino los soles por día que deja, y ese recién
--    se veía cuando el ciclo ya estaba abierto y era tarde para
--    cambiar de idea. Un ahorro ambicioso que se rompe cada
--    quincena ahorra menos que uno modesto que se cumple.
-- ============================================================

-- ------------------------------------------------------------
-- La marca
-- ------------------------------------------------------------
alter table periodos
  add column if not exists atipico boolean not null default false;

comment on column periodos.atipico is
  'Ciclo real pero no comparable: no siembra la config del siguiente '
  'ni entra en promedios. Sigue apareciendo en el histórico, marcado.';

-- ------------------------------------------------------------
-- Un ciclo atípico no siembra las reglas del siguiente
--
-- abrir_ciclo() copiaba la config del ciclo anterior sin más. Con
-- un mes de limpieza de deudas detrás —pct_ahorro = 0, alertas
-- apagadas— el ciclo nuevo nacía sin ahorro y sin avisos, que es
-- lo contrario de lo que quieres justo cuando empiezas en serio.
-- Ahora copia del último ciclo comparable; si no hay ninguno, usa
-- los valores por defecto de la tabla.
-- ------------------------------------------------------------
create or replace function abrir_ciclo(
  p_inicio   date,
  p_etiqueta text default null
)
returns uuid
language plpgsql as $$
declare
  v_anterior uuid;
  v_nuevo    uuid;
begin
  select id into v_anterior
  from periodos where cerrado = false limit 1;

  if v_anterior is not null then
    raise exception 'Ya hay un ciclo abierto (%). Ciérralo primero.', v_anterior;
  end if;

  select id into v_anterior
  from periodos
  where not atipico
  order by inicio desc
  limit 1;

  insert into periodos (inicio, fin, etiqueta)
  values (
    p_inicio,
    (p_inicio + interval '1 month' - interval '1 day')::date,
    coalesce(p_etiqueta, to_char(p_inicio + interval '1 month', 'TMMonth YYYY'))
  )
  returning id into v_nuevo;

  if v_anterior is not null then
    insert into config_ciclo (
      periodo_id, pct_ahorro, pct_colchon, monto_esposa,
      umbral_ambar, umbral_rojo, caida_permitido,
      dias_min_alerta, dia_inicio_eval
    )
    select v_nuevo, pct_ahorro, pct_colchon, monto_esposa,
           umbral_ambar, umbral_rojo, caida_permitido,
           dias_min_alerta, dia_inicio_eval
    from config_ciclo where periodo_id = v_anterior;
  else
    insert into config_ciclo (periodo_id) values (v_nuevo);
  end if;

  update ingresos    set periodo_id = v_nuevo where periodo_id is null;
  update movimientos set periodo_id = v_nuevo where periodo_id is null;

  return v_nuevo;
end;
$$;

-- ------------------------------------------------------------
-- El histórico marca los atípicos en vez de esconderlos
--
-- Esconderlos sería mentir: el mes existió y la plata salió. Van
-- en la lista con la marca puesta, y quien lee decide.
-- ------------------------------------------------------------
create or replace function panel(p_periodo uuid default null)
returns jsonb
language plpgsql stable as $$
declare
  e   record;
  c   record;
  out jsonb;
begin
  select * into e from estado_ciclo(p_periodo);
  if not found then
    return jsonb_build_object('estado', null, 'error', 'No hay ciclo abierto');
  end if;

  select * into c from config_ciclo where config_ciclo.periodo_id = e.periodo_id;

  out := jsonb_build_object(
    'generado_en', now(),
    'hoy',         hoy_lima(),
    'estado',      to_jsonb(e),
    'atipico',     coalesce((select p.atipico from periodos p where p.id = e.periodo_id), false),
    'config',      jsonb_build_object(
      'pct_ahorro',      c.pct_ahorro,
      'pct_colchon',     c.pct_colchon,
      'monto_esposa',    c.monto_esposa,
      'umbral_ambar',    c.umbral_ambar,
      'umbral_rojo',     c.umbral_rojo,
      'dia_inicio_eval', c.dia_inicio_eval,
      'alertas_activas', c.alertas_activas,
      'estado_alerta',   c.estado_alerta,
      'ultima_alerta',   c.ultima_alerta
    )
  );

  out := out || jsonb_build_object('por_categoria', (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.monto desc), '[]'::jsonb)
    from (
      select coalesce(m.categoria, 'sin categoría') as categoria,
             round(sum(m.monto), 2) as monto,
             count(*)::int          as n
      from movimientos m
      where m.periodo_id = e.periodo_id
        and m.fijo_id is null and m.servicio_id is null
        and m.tipo not in ('consumo_monedero', 'pago_tarjeta')
      group by 1
    ) t
  ));

  out := out || jsonb_build_object('por_metodo', (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.monto desc), '[]'::jsonb)
    from (
      select m.banco, m.tipo,
             (m.tipo = 'credito')  as a_credito,
             round(sum(m.monto), 2) as monto,
             count(*)::int          as n
      from movimientos m
      where m.periodo_id = e.periodo_id
        and m.fijo_id is null and m.servicio_id is null
        and m.tipo not in ('consumo_monedero', 'pago_tarjeta')
      group by 1, 2, 3
    ) t
  ));

  out := out || jsonb_build_object('por_dia', (
    with dias as (
      select generate_series(e.inicio, least(e.fin, hoy_lima()), '1 day')::date as fecha
    ),
    g as (
      select (m.fecha at time zone 'America/Lima')::date as f,
             sum(m.monto) as monto
      from movimientos m
      where m.periodo_id = e.periodo_id
        and m.fijo_id is null and m.servicio_id is null
        and m.tipo not in ('consumo_monedero', 'pago_tarjeta')
      group by 1
    )
    select coalesce(jsonb_agg(to_jsonb(t) order by t.fecha), '[]'::jsonb)
    from (
      select d.fecha,
             (d.fecha - e.inicio + 1)::int as dia,
             round(coalesce(g.monto, 0), 2) as monto,
             round(sum(coalesce(g.monto, 0)) over (order by d.fecha), 2) as acumulado,
             round(e.bolsa * (d.fecha - e.inicio + 1) / greatest(e.dias_ciclo, 1), 2) as ideal
      from dias d
      left join g on g.f = d.fecha
    ) t
  ));

  out := out || jsonb_build_object('movimientos', (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.fecha desc), '[]'::jsonb)
    from (
      select m.id, m.fecha, m.monto, m.comercio, m.categoria,
             m.banco, m.tipo, m.origen, m.confirmado,
             f.nombre as fijo, s.nombre as servicio,
             m.raw->>'nota' as nota
      from movimientos m
      left join fijos     f on f.id = m.fijo_id
      left join servicios s on s.id = m.servicio_id
      where m.periodo_id = e.periodo_id
      order by m.fecha desc
      limit 40
    ) t
  ));

  out := out || jsonb_build_object('ingresos', (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.fecha desc), '[]'::jsonb)
    from (
      select i.id, i.fuente, i.monto, i.fecha, i.confirmado,
             i.es_retiro, i.principal, i.nota
      from ingresos i
      where i.periodo_id = e.periodo_id
    ) t
  ));

  out := out || jsonb_build_object('fijos', (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.nombre), '[]'::jsonb)
    from (
      select f.nombre, f.monto, f.dia_aprox,
             exists (
               select 1 from movimientos m
               where m.fijo_id = f.id and m.periodo_id = e.periodo_id
             ) as pagado
      from fijos f where f.activo
    ) t
  ));

  out := out || jsonb_build_object('servicios', (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.nombre), '[]'::jsonb)
    from (
      select s.nombre, s.empresa, s.monto_estimado as estimado,
             s.dia_aprox, s.vence_el,
             (select round(sum(m.monto), 2) from movimientos m
              where m.servicio_id = s.id and m.periodo_id = e.periodo_id) as pagado
      from servicios s where s.activo
    ) t
  ));

  out := out || jsonb_build_object('sin_resolver', (
    select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from sin_resolver() t
  ));

  out := out || jsonb_build_object('recibos_pendientes', (
    select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from recibos_pendientes() t
  ));

  out := out || jsonb_build_object('historial', (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.inicio), '[]'::jsonb)
    from (
      select pr.id, pr.etiqueta, pr.inicio, pr.fin, pr.sobrante, pr.atipico,
             (select coalesce(round(sum(i.monto), 2), 0) from ingresos i
              where i.periodo_id = pr.id and i.confirmado and not i.es_retiro) as ingreso,
             (select coalesce(round(sum(m.monto), 2), 0) from movimientos m
              where m.periodo_id = pr.id
                and m.fijo_id is null and m.servicio_id is null
                and m.tipo not in ('consumo_monedero', 'pago_tarjeta')) as gastado
      from periodos pr
      where pr.cerrado
      order by pr.inicio desc
      limit 12
    ) t
  ));

  return out;
end;
$$;

-- ============================================================
-- Elegir el % de ahorro mirando los soles por día
--
-- El porcentaje es la perilla, pero no es el número que se vive.
-- El que se vive es cuánto puedes gastar hoy. Estas dos funciones
-- traducen entre los dos antes de abrir el ciclo, que es cuando
-- todavía se puede cambiar de idea.
--
-- Los fijos, los servicios y el monto de la esposa se leen de lo
-- que ya está cargado si no los pasas. Así la simulación usa tus
-- números y no unos inventados.
-- ============================================================

-- ------------------------------------------------------------
-- El abanico: qué te deja cada porcentaje
--
--   select * from simular_ciclo(7300);
-- ------------------------------------------------------------
create or replace function simular_ciclo(
  p_ingreso   numeric,
  p_dias      int     default 30,
  p_esposa    numeric default null,
  p_fijos     numeric default null,
  p_servicios numeric default null
)
returns table (
  pct_ahorro numeric,
  ahorro     numeric,
  bolsa      numeric,
  por_dia    numeric,
  por_semana numeric
)
language plpgsql stable as $$
declare
  v_esposa numeric;
  v_fijos  numeric;
  v_serv   numeric;
  v_dias   int := greatest(coalesce(p_dias, 30), 1);
begin
  v_esposa := coalesce(
    p_esposa,
    (select cc.monto_esposa from config_ciclo cc where cc.periodo_id = ciclo_actual()),
    0);
  v_fijos := coalesce(
    p_fijos,
    (select sum(monto) from fijos where activo),
    0);
  v_serv := coalesce(
    p_servicios,
    (select sum(monto_estimado) from servicios where activo),
    0);

  return query
  select pct::numeric,
         round(p_ingreso * pct / 100, 2),
         round(p_ingreso * (100 - pct) / 100 - v_esposa - v_fijos - v_serv, 2),
         round((p_ingreso * (100 - pct) / 100 - v_esposa - v_fijos - v_serv) / v_dias, 2),
         round((p_ingreso * (100 - pct) / 100 - v_esposa - v_fijos - v_serv) / v_dias * 7, 2)
  from generate_series(0, 45, 5) as pct;
end;
$$;

-- ------------------------------------------------------------
-- El camino inverso: sé cuánto gasto al día, ¿cuánto puedo ahorrar?
--
--   select * from pct_ahorro_para(7300, 85);
--
-- Es la pregunta honesta. Un porcentaje que rompes cada quincena
-- ahorra menos que uno más chico que cumples: el sobrante se
-- barre al ahorro igual en cerrar_ciclo(), así que los meses
-- buenos devuelven la diferencia sola.
-- ------------------------------------------------------------
create or replace function pct_ahorro_para(
  p_ingreso   numeric,
  p_gasto_dia numeric,
  p_dias      int     default 30,
  p_esposa    numeric default null,
  p_fijos     numeric default null,
  p_servicios numeric default null
)
returns table (
  pct_ahorro numeric,
  ahorro     numeric,
  bolsa      numeric,
  por_dia    numeric,
  nota       text
)
language plpgsql stable as $$
declare
  v_esposa numeric;
  v_fijos  numeric;
  v_serv   numeric;
  v_dias   int := greatest(coalesce(p_dias, 30), 1);
  v_bolsa  numeric;
  v_aho    numeric;
  v_pct    numeric;
begin
  v_esposa := coalesce(
    p_esposa,
    (select cc.monto_esposa from config_ciclo cc where cc.periodo_id = ciclo_actual()),
    0);
  v_fijos := coalesce(
    p_fijos, (select sum(monto) from fijos where activo), 0);
  v_serv := coalesce(
    p_servicios, (select sum(monto_estimado) from servicios where activo), 0);

  v_bolsa := round(p_gasto_dia * v_dias, 2);
  v_aho   := round(p_ingreso - v_esposa - v_fijos - v_serv - v_bolsa, 2);
  v_pct   := case when p_ingreso > 0
                  then round(v_aho / p_ingreso * 100, 2) else 0 end;

  return query select
    v_pct, v_aho, v_bolsa, round(p_gasto_dia, 2),
    case
      when v_aho < 0 then
        format('No alcanza: gastar %s al día pide %s más de lo que entra. '
               'Baja el gasto diario o los fijos.',
               soles(p_gasto_dia), soles(-v_aho))
      when v_pct < 10 then
        format('Ajustado: solo %s%% al ahorro. Alcanza, pero no avanza hacia la meta.',
               v_pct)
      else
        format('Viable: %s%% al ahorro (%s al mes).', v_pct, soles(v_aho))
    end;
end;
$$;
