-- ============================================================
-- Ingresos esperados y cobrados
--
-- Con ciclos de calendario el sueldo se registra el día 1 y cae a
-- fin de mes. Hasta acá eso era una fila con nota = 'esperado' y
-- nada más: la bolsa la contaba —bien, mide margen y no caja—
-- pero no había forma de decir "ya me pagaron", ni de enterarse
-- si llegó corto.
--
-- `recibido_el` nulo es un ingreso que todavía no cae. Sigue
-- sumando a la bolsa igual que antes: lo único que cambia es que
-- ahora se ve cuánto del ciclo está apoyado en plata que no ha
-- llegado, y al cobrar se corrige el monto si vino distinto.
-- ============================================================

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_name = 'ingresos' and column_name = 'recibido_el'
  ) then
    alter table ingresos add column recibido_el    date;
    alter table ingresos add column monto_esperado numeric(12,2);

    -- Lo que ya estaba: cobrado, salvo lo declarado por adelantado
    -- en un ciclo que sigue abierto.
    update ingresos i set recibido_el = i.fecha
    where coalesce(i.nota, '') not like 'esperado%'
       or exists (select 1 from periodos p where p.id = i.periodo_id and p.cerrado);

    update ingresos set monto_esperado = monto where recibido_el is null;
  end if;
end $$;

-- Un ingreso que entra sin decir nada ya está en la mano: es lo
-- que mandan el Atajo y registrar_ingreso(). Solo rotar_ciclo()
-- escribe el nulo a propósito.
alter table ingresos alter column recibido_el set default hoy_lima();

comment on column ingresos.recibido_el is
  'Día en que la plata cayó. Nulo = esperado: cuenta en la bolsa pero aún no llega.';
comment on column ingresos.monto_esperado is
  'Lo que se declaró al abrir el ciclo. `monto` pasa a ser lo que de verdad llegó.';

-- ============================================================
-- Marcar un ingreso como cobrado
--
-- Si llegó un monto distinto se corrige `monto` y la bolsa se
-- recalcula sola; lo esperado queda en `monto_esperado`. Era el
-- riesgo abierto de registrar por adelantado: un sueldo que llega
-- corto y el motor no se entera.
-- ============================================================
create or replace function cobrar_ingreso(
  p_id    uuid,
  p_monto numeric default null,
  p_fecha date    default null
)
returns jsonb
language plpgsql as $$
declare
  v_ing   ingresos;
  v_monto numeric;
  v_dif   numeric;
begin
  select * into v_ing from ingresos where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Ese ingreso no existe');
  end if;
  if v_ing.recibido_el is not null then
    return jsonb_build_object('ok', false, 'error',
      format('%s ya figura cobrado el %s', v_ing.fuente, v_ing.recibido_el));
  end if;

  v_monto := coalesce(p_monto, v_ing.monto);
  if v_monto <= 0 then
    return jsonb_build_object('ok', false, 'error', 'Monto inválido');
  end if;

  update ingresos set
    recibido_el    = coalesce(p_fecha, hoy_lima()),
    monto_esperado = coalesce(monto_esperado, monto),
    monto          = v_monto
  where id = p_id;

  v_dif := v_monto - coalesce(v_ing.monto_esperado, v_ing.monto);

  return jsonb_build_object(
    'ok', true, 'id', p_id, 'monto', v_monto, 'diferencia', v_dif,
    'mensaje', case
      when v_dif < 0 then format('%s cobrado: %s, %s menos de lo esperado. La bolsa bajó.',
                                 v_ing.fuente, soles(v_monto), soles(-v_dif))
      when v_dif > 0 then format('%s cobrado: %s, %s más de lo esperado.',
                                 v_ing.fuente, soles(v_monto), soles(v_dif))
      else format('%s cobrado: %s', v_ing.fuente, soles(v_monto))
    end,
    'estado', (select to_jsonb(t) from estado_ciclo(v_ing.periodo_id) t)
  );
end;
$$;

-- ============================================================
-- rotar_ciclo(): dos cambios
--
--   · los ingresos declarados entran como esperados
--     (recibido_el nulo), no como cobrados
--   · lo registrado desde el día de inicio en adelante se va al
--     ciclo nuevo. Rotar el 1 a mediodía dejaba el desayuno del 1
--     en el ciclo de setiembre, restando de un sobrante que ya no
--     le correspondía.
-- ============================================================
create or replace function rotar_ciclo(
  p_inicio    date    default null,
  p_etiqueta  text    default null,
  p_ingresos  jsonb   default null,   -- [{fuente, monto, principal, nota}]
  p_config    jsonb   default null    -- {pct_ahorro, monto_esposa, ...}
)
returns jsonb
language plpgsql as $$
declare
  v_ini      date := coalesce(p_inicio, hoy_lima());
  v_actual   periodos;
  v_sobrante numeric;
  v_nuevo    uuid;
  v_ing      jsonb;
  v_n        int := 0;
  v_mov      int := 0;
  v_mov_ing  int := 0;
begin
  select * into v_actual from periodos where cerrado = false limit 1;

  if v_actual.id is not null then
    if v_ini <= v_actual.inicio then
      return jsonb_build_object('ok', false,
        'error', format('El ciclo abierto (%s) empieza el %s; el nuevo tiene que empezar después.',
                        coalesce(v_actual.etiqueta, 'sin nombre'), v_actual.inicio));
    end if;
    v_sobrante := cerrar_ciclo(v_actual.id, (v_ini - 1)::date);
  end if;

  v_nuevo := abrir_ciclo(v_ini, p_etiqueta);

  if v_actual.id is not null then
    update movimientos set periodo_id = v_nuevo
    where periodo_id = v_actual.id
      and (fecha at time zone 'America/Lima')::date >= v_ini;
    get diagnostics v_mov = row_count;

    update ingresos set periodo_id = v_nuevo
    where periodo_id = v_actual.id and fecha >= v_ini;
    get diagnostics v_mov_ing = row_count;

    -- El sobrante se calculó con esos movimientos adentro
    if v_mov + v_mov_ing > 0 then
      v_sobrante := cerrar_ciclo(v_actual.id, (v_ini - 1)::date);
    end if;
  end if;

  if p_ingresos is not null then
    for v_ing in select value from jsonb_array_elements(p_ingresos) loop
      insert into ingresos (fuente, monto, monto_esperado, fecha, confirmado,
                            principal, nota, recibido_el)
      values (
        coalesce(nullif(btrim(v_ing->>'fuente'), ''), 'Sin fuente'),
        (v_ing->>'monto')::numeric,
        (v_ing->>'monto')::numeric,
        v_ini,
        true,
        coalesce((v_ing->>'principal')::boolean, false),
        v_ing->>'nota',
        null
      );
      v_n := v_n + 1;
    end loop;
  end if;

  if p_config is not null then
    update config_ciclo set
      pct_ahorro      = coalesce((p_config->>'pct_ahorro')::numeric,      pct_ahorro),
      monto_esposa    = coalesce((p_config->>'monto_esposa')::numeric,    monto_esposa),
      dia_inicio_eval = coalesce((p_config->>'dia_inicio_eval')::int,     dia_inicio_eval),
      alertas_activas = coalesce((p_config->>'alertas_activas')::boolean, alertas_activas)
    where periodo_id = v_nuevo;
  end if;

  return jsonb_build_object(
    'ok', true,
    'periodo_id', v_nuevo,
    'cerrado', v_actual.id,
    'sobrante', v_sobrante,
    'ingresos', v_n,
    'movidos', v_mov,
    'mensaje', case
      when v_actual.id is null then 'Ciclo abierto'
      else format('Ciclo anterior cerrado con %s al ahorro', soles(v_sobrante))
    end,
    'estado', (select to_jsonb(t) from estado_ciclo() t)
  );
end;
$$;

-- ------------------------------------------------------------
-- panel(): cada ingreso dice si ya cayó, y `cobro` resume cuánto
-- del ciclo sigue apoyado en plata que no ha llegado
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
