-- ============================================================
-- El día: cuánto tocaba y cuánto se fue
--
-- `permitido_dia` reparte lo que queda entre los días que faltan,
-- contando hoy. Sirve para planear, pero como respuesta a "¿puedo
-- gastar más hoy?" miente: después de gastar 220 en un día que
-- daba para 53, seguía diciendo "hoy puedes gastar 45" — el
-- exceso ya estaba repartido entre los 31 días y no se veía.
--
-- El presupuesto del día se fija con lo que había al amanecer y
-- no se mueve con lo que gastas. Lo que se mueve es cuánto te
-- queda de él, y eso sí puede salir negativo.
-- ============================================================
create or replace function estado_dia(p_periodo uuid default null)
returns jsonb
language plpgsql stable as $$
declare
  e      record;
  v_hoy  numeric;
  v_pres numeric;
  v_plan numeric;
begin
  select * into e from estado_ciclo(p_periodo);
  if not found then return null; end if;

  select coalesce(sum(monto), 0) into v_hoy
  from movimientos
  where periodo_id = e.periodo_id
    and fijo_id is null and servicio_id is null
    and tipo not in ('consumo_monedero', 'pago_tarjeta')
    and (fecha at time zone 'America/Lima')::date = hoy_lima();

  -- Lo que había al empezar el día, entre los días que quedaban
  v_pres := round((e.disponible + v_hoy) / e.dias_restantes, 2);
  v_plan := round(e.bolsa * e.dia_actual / greatest(e.dias_ciclo, 1), 2);

  return jsonb_build_object(
    'gastado_hoy',     v_hoy,
    'presupuesto_hoy', v_pres,
    'queda_hoy',       v_pres - v_hoy,
    -- Contra la bolsa repartida pareja: positivo = gastaste de más
    'plan_acumulado',  v_plan,
    'desvio',          e.gastado - v_plan,
    'desde_manana',    case when e.dias_restantes > 1
                            then round(e.disponible / (e.dias_restantes - 1), 2) end
  );
end;
$$;

-- ------------------------------------------------------------
-- panel(): agrega `dia`
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

  -- Sin ciclo abierto el panel igual tiene que poder trabajar:
  -- es justo cuando hay que abrir uno, y para eso necesita ver
  -- los fijos y servicios que ya están cargados.
  if not found then
    return jsonb_build_object(
      'estado', null,
      'hoy',    hoy_lima(),
      'error',  'No hay ciclo abierto',
      'fijos', (
        select coalesce(jsonb_agg(to_jsonb(t) order by t.nombre), '[]'::jsonb)
        from (select f.id, f.nombre, f.monto, f.dia_aprox, false as pagado
              from fijos f where f.activo) t),
      'servicios', (
        select coalesce(jsonb_agg(to_jsonb(t) order by t.nombre), '[]'::jsonb)
        from (select s.id, s.nombre, s.empresa, s.monto_estimado as estimado,
                     s.dia_aprox, s.vence_el, null::numeric as pagado
              from servicios s where s.activo) t)
    );
  end if;

  select * into c from config_ciclo where config_ciclo.periodo_id = e.periodo_id;

  out := jsonb_build_object(
    'generado_en', now(),
    'dia',         estado_dia(e.periodo_id),
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
      'ultima_alerta',   c.ultima_alerta,
      'editado_en',      c.editado_en,
      'nota_edicion',    c.nota_edicion
    )
  );

  out := out || jsonb_build_object('por_categoria', (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.monto desc), '[]'::jsonb)
    from (
      select coalesce(m.categoria, 'sin categoría') as categoria,
             round(sum(m.monto), 2) as monto, count(*)::int as n
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
      select m.banco, m.tipo, (m.tipo = 'credito') as a_credito,
             round(sum(m.monto), 2) as monto, count(*)::int as n
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
      select (m.fecha at time zone 'America/Lima')::date as f, sum(m.monto) as monto
      from movimientos m
      where m.periodo_id = e.periodo_id
        and m.fijo_id is null and m.servicio_id is null
        and m.tipo not in ('consumo_monedero', 'pago_tarjeta')
      group by 1
    )
    select coalesce(jsonb_agg(to_jsonb(t) order by t.fecha), '[]'::jsonb)
    from (
      select d.fecha, (d.fecha - e.inicio + 1)::int as dia,
             round(coalesce(g.monto, 0), 2) as monto,
             round(sum(coalesce(g.monto, 0)) over (order by d.fecha), 2) as acumulado,
             round(e.bolsa * (d.fecha - e.inicio + 1) / greatest(e.dias_ciclo, 1), 2) as ideal
      from dias d left join g on g.f = d.fecha
    ) t
  ));

  out := out || jsonb_build_object('movimientos', (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.fecha desc), '[]'::jsonb)
    from (
      select m.id, m.fecha, m.monto, m.comercio, m.categoria,
             m.banco, m.tipo, m.origen, m.confirmado,
             f.nombre as fijo, s.nombre as servicio, m.raw->>'nota' as nota
      from movimientos m
      left join fijos     f on f.id = m.fijo_id
      left join servicios s on s.id = m.servicio_id
      where m.periodo_id = e.periodo_id
      order by m.fecha desc limit 40
    ) t
  ));

  out := out || jsonb_build_object('ingresos', (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.fecha desc), '[]'::jsonb)
    from (
      select i.id, i.fuente, i.monto, i.fecha, i.confirmado,
             i.es_retiro, i.principal, i.nota,
             i.recibido_el, i.monto_esperado
      from ingresos i where i.periodo_id = e.periodo_id
    ) t
  ));

  out := out || jsonb_build_object('cobro', (
    select jsonb_build_object(
      'por_cobrar', coalesce(round(sum(i.monto) filter (where i.recibido_el is null), 2), 0),
      'cobrado',    coalesce(round(sum(i.monto) filter (where i.recibido_el is not null), 2), 0),
      'esperado',   coalesce(round(sum(coalesce(i.monto_esperado, i.monto)), 2), 0))
    from ingresos i
    where i.periodo_id = e.periodo_id and i.confirmado and not i.es_retiro
  ));

  out := out || jsonb_build_object('fijos', (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.nombre), '[]'::jsonb)
    from (
      select f.id, f.nombre, f.monto, f.dia_aprox,
             exists (select 1 from movimientos m
                     where m.fijo_id = f.id and m.periodo_id = e.periodo_id) as pagado
      from fijos f where f.activo
    ) t
  ));

  out := out || jsonb_build_object('servicios', (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.nombre), '[]'::jsonb)
    from (
      select s.id, s.nombre, s.empresa, s.monto_estimado as estimado,
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
      from periodos pr where pr.cerrado
      order by pr.inicio desc limit 12
    ) t
  ));

  return out;
end;
$$;
