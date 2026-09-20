-- ============================================================
-- Las escrituras del panel
--
-- Hasta acá el panel era de solo lectura y todo cambio pasaba
-- por el SQL Editor. Eso funciona una vez; no funciona el día 1
-- de cada mes desde el celular.
--
-- Cada acción es una función de Postgres y el endpoint solo la
-- llama. Misma razón que con los números: una sola fuente. Si la
-- lógica de "pagar un servicio" viviera en el navegador, habría
-- dos versiones de la regla y la del celular sería la que se usa.
--
-- Ninguna de estas funciones borra nada. Los fijos y servicios se
-- desactivan (`activo = false`), no se eliminan: un movimiento
-- viejo enlazado a un servicio borrado perdería el enlace y
-- volvería a contar como gasto variable de un ciclo ya cerrado.
-- ============================================================

-- ------------------------------------------------------------
-- El panel necesita los ids para poder editar
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
             i.es_retiro, i.principal, i.nota
      from ingresos i where i.periodo_id = e.periodo_id
    ) t
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

-- ============================================================
-- 1 · Registrar el pago de un fijo o un servicio
--
-- Es lo único del flujo manual que todavía pedía SQL, y el error
-- que evita es caro: pagar el alquiler con el Atajo "Gasto" lo
-- mete como gasto variable y se come la bolsa dos veces — una
-- como fijo descontado el día 1 y otra como movimiento.
--
-- Al pagar un servicio se adelanta `vence_el` un mes. Sin eso,
-- recibos_pendientes() vuelve a gritar por el recibo del mes
-- pasado apenas empieza el ciclo siguiente.
-- ============================================================
create or replace function registrar_pago(
  p_clase text,                 -- 'fijo' | 'servicio'
  p_id    uuid,
  p_monto numeric,
  p_banco text default 'BCP',
  p_tipo  text default 'debito',
  p_nota  text default null
)
returns jsonb
language plpgsql as $$
declare
  v_mov    uuid;
  v_nombre text;
  v_vence  date;
begin
  if p_monto is null or p_monto <= 0 then
    return jsonb_build_object('ok', false, 'error', 'Monto inválido');
  end if;

  if lower(coalesce(p_clase, '')) = 'fijo' then
    select nombre into v_nombre from fijos where id = p_id;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'Ese fijo no existe');
    end if;

    insert into movimientos (fecha, monto, banco, tipo, origen, confirmado, fijo_id, raw)
    values (now(), p_monto, p_banco, p_tipo, 'manual', true, p_id,
            jsonb_build_object('nota', p_nota, 'via', 'panel'))
    returning id into v_mov;

  elsif lower(coalesce(p_clase, '')) = 'servicio' then
    select nombre, vence_el into v_nombre, v_vence from servicios where id = p_id;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'Ese servicio no existe');
    end if;

    insert into movimientos (fecha, monto, banco, tipo, origen, confirmado, servicio_id, raw)
    values (now(), p_monto, p_banco, p_tipo, 'manual', true, p_id,
            jsonb_build_object('nota', p_nota, 'via', 'panel'))
    returning id into v_mov;

    if v_vence is not null then
      v_vence := (v_vence + interval '1 month')::date;
      update servicios set vence_el = v_vence where id = p_id;
    end if;

    -- El estimado sigue a los últimos 3 pagos reales
    perform recalcular_estimados();

  else
    return jsonb_build_object('ok', false, 'error', 'Clase debe ser fijo o servicio');
  end if;

  return jsonb_build_object(
    'ok', true, 'id', v_mov, 'nombre', v_nombre, 'monto', p_monto,
    'vence_el', v_vence,
    'mensaje', format('%s pagado: %s', v_nombre, soles(p_monto)),
    'estado', (select to_jsonb(t) from estado_ciclo() t)
  );
end;
$$;

-- ============================================================
-- 2 · Empezar un ciclo
--
-- El ritual del día 1, en una sola llamada y una sola
-- transacción: cierra el anterior (barriendo el sobrante al
-- ahorro), abre el nuevo, registra los ingresos que ya sabes que
-- vienen y fija las reglas.
--
-- Va junto y no en cuatro pasos porque a medio camino el estado
-- es incoherente: un ciclo abierto sin ingresos tiene la bolsa en
-- negativo y sale rojo. Si algo falla, no pasa nada.
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
begin
  select * into v_actual from periodos where cerrado = false limit 1;

  if v_actual.id is not null then
    if v_ini <= v_actual.inicio then
      return jsonb_build_object('ok', false,
        'error', format('El ciclo abierto empieza el %s; el nuevo no puede empezar antes.',
                        v_actual.inicio));
    end if;
    v_sobrante := cerrar_ciclo(v_actual.id, (v_ini - 1)::date);
  end if;

  v_nuevo := abrir_ciclo(v_ini, p_etiqueta);

  if p_ingresos is not null then
    for v_ing in select value from jsonb_array_elements(p_ingresos) loop
      insert into ingresos (fuente, monto, fecha, confirmado, principal, nota)
      values (
        coalesce(nullif(btrim(v_ing->>'fuente'), ''), 'Sin fuente'),
        (v_ing->>'monto')::numeric,
        v_ini,
        true,
        coalesce((v_ing->>'principal')::boolean, false),
        v_ing->>'nota'
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
    'mensaje', case
      when v_actual.id is null then 'Ciclo abierto'
      else format('Ciclo anterior cerrado con %s al ahorro', soles(v_sobrante))
    end,
    'estado', (select to_jsonb(t) from estado_ciclo() t)
  );
end;
$$;

-- ============================================================
-- 3 · Cambiar las reglas del ciclo
--
-- Un null deja el valor como está. Toda edición deja rastro:
-- cambiar el % a mitad de camino encoge la bolsa de golpe y el
-- permitido diario cae con ella — puedes saltar a rojo por un
-- cambio de regla y no por haber gastado. Seis meses después,
-- `nota_edicion` es lo único que lo explica.
-- ============================================================
create or replace function actualizar_config(
  p_pct_ahorro      numeric default null,
  p_monto_esposa    numeric default null,
  p_dia_inicio_eval int     default null,
  p_alertas_activas boolean default null,
  p_pct_colchon     numeric default null,
  p_nota            text    default null
)
returns jsonb
language plpgsql as $$
declare
  v_periodo uuid := ciclo_actual();
  v_antes   numeric;
begin
  if v_periodo is null then
    return jsonb_build_object('ok', false, 'error', 'No hay ciclo abierto');
  end if;

  if p_pct_ahorro is not null and (p_pct_ahorro < 0 or p_pct_ahorro > 100) then
    return jsonb_build_object('ok', false, 'error', 'El % de ahorro va de 0 a 100');
  end if;

  select pct_ahorro into v_antes from config_ciclo where periodo_id = v_periodo;

  update config_ciclo set
    pct_ahorro      = coalesce(p_pct_ahorro,      pct_ahorro),
    monto_esposa    = coalesce(p_monto_esposa,    monto_esposa),
    dia_inicio_eval = coalesce(p_dia_inicio_eval, dia_inicio_eval),
    alertas_activas = coalesce(p_alertas_activas, alertas_activas),
    pct_colchon     = coalesce(p_pct_colchon,     pct_colchon),
    editado_en      = now(),
    nota_edicion    = coalesce(
      p_nota,
      case when p_pct_ahorro is not null and p_pct_ahorro <> v_antes
           then format('ahorro %s%% → %s%%', v_antes, p_pct_ahorro) end,
      nota_edicion)
  where periodo_id = v_periodo;

  return jsonb_build_object(
    'ok', true, 'mensaje', 'Reglas actualizadas',
    'estado', (select to_jsonb(t) from estado_ciclo() t)
  );
end;
$$;

-- ============================================================
-- 4 · Fijos y servicios
--
-- `p_id` nulo crea; con id, edita. Nunca borran: desactivan. Un
-- movimiento viejo enlazado a un servicio borrado perdería el
-- enlace y volvería a contar como gasto variable de un ciclo ya
-- cerrado.
-- ============================================================
create or replace function guardar_fijo(
  p_id        uuid    default null,
  p_nombre    text    default null,
  p_monto     numeric default null,
  p_dia_aprox int     default null,
  p_activo    boolean default null
)
returns jsonb
language plpgsql as $$
declare v_id uuid;
begin
  if p_id is null then
    if coalesce(btrim(p_nombre), '') = '' or p_monto is null then
      return jsonb_build_object('ok', false, 'error', 'Un fijo nuevo necesita nombre y monto');
    end if;
    insert into fijos (nombre, monto, dia_aprox, activo)
    values (btrim(p_nombre), p_monto, p_dia_aprox, coalesce(p_activo, true))
    returning id into v_id;
  else
    update fijos set
      nombre    = coalesce(nullif(btrim(p_nombre), ''), nombre),
      monto     = coalesce(p_monto,     monto),
      dia_aprox = coalesce(p_dia_aprox, dia_aprox),
      activo    = coalesce(p_activo,    activo)
    where id = p_id
    returning id into v_id;

    if v_id is null then
      return jsonb_build_object('ok', false, 'error', 'Ese fijo no existe');
    end if;
  end if;

  return jsonb_build_object(
    'ok', true, 'id', v_id, 'mensaje', 'Fijo guardado',
    'estado', (select to_jsonb(t) from estado_ciclo() t)
  );
end;
$$;

create or replace function guardar_servicio(
  p_id        uuid    default null,
  p_nombre    text    default null,
  p_estimado  numeric default null,
  p_dia_aprox int     default null,
  p_vence_el  date    default null,
  p_empresa   text    default null,
  p_activo    boolean default null
)
returns jsonb
language plpgsql as $$
declare v_id uuid;
begin
  if p_id is null then
    if coalesce(btrim(p_nombre), '') = '' or p_estimado is null then
      return jsonb_build_object('ok', false, 'error', 'Un servicio nuevo necesita nombre y estimado');
    end if;
    insert into servicios (nombre, empresa, monto_estimado, dia_aprox, vence_el, activo)
    values (btrim(p_nombre), nullif(btrim(p_empresa), ''), p_estimado,
            p_dia_aprox, p_vence_el, coalesce(p_activo, true))
    returning id into v_id;
  else
    update servicios set
      nombre         = coalesce(nullif(btrim(p_nombre), ''), nombre),
      empresa        = coalesce(nullif(btrim(p_empresa), ''), empresa),
      monto_estimado = coalesce(p_estimado,  monto_estimado),
      dia_aprox      = coalesce(p_dia_aprox, dia_aprox),
      vence_el       = coalesce(p_vence_el,  vence_el),
      activo         = coalesce(p_activo,    activo)
    where id = p_id
    returning id into v_id;

    if v_id is null then
      return jsonb_build_object('ok', false, 'error', 'Ese servicio no existe');
    end if;
  end if;

  return jsonb_build_object(
    'ok', true, 'id', v_id, 'mensaje', 'Servicio guardado',
    'estado', (select to_jsonb(t) from estado_ciclo() t)
  );
end;
$$;

-- ------------------------------------------------------------
-- El abanico de porcentajes para el ciclo abierto
--
-- Lo usa el control deslizante del panel: se pide una vez al
-- abrir el formulario y el deslizador solo indexa. Así el número
-- que ves al mover el dedo sigue saliendo de Postgres y no de una
-- fórmula repetida en el navegador.
-- ------------------------------------------------------------
create or replace function simular_actual()
returns jsonb
language plpgsql stable as $$
declare e record; c record;
begin
  select * into e from estado_ciclo();
  if not found then return '[]'::jsonb; end if;
  select * into c from config_ciclo where periodo_id = e.periodo_id;

  return (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.pct_ahorro), '[]'::jsonb)
    from simular_ciclo(e.ingreso + e.retiros, e.dias_ciclo, c.monto_esposa) t
  );
end;
$$;

-- ------------------------------------------------------------
-- registrar_ingreso() con freno de rotación
--
-- Con ciclos de calendario el ciclo lo abre rotar_ciclo(), no el
-- ingreso. El panel manda p_rotar = false para poder registrar el
-- sueldo como principal sin que se dispare una rotación. El Atajo
-- de iOS no manda nada y conserva el comportamiento de siempre.
-- ------------------------------------------------------------
-- Las dos firmas: la de 006 y la de esta migración. Sin la segunda,
-- volver a correr el archivo falla con "already exists".
drop function if exists registrar_ingreso(text, numeric, text, text, boolean, int);
drop function if exists registrar_ingreso(text, numeric, text, text, boolean, int, boolean);

create function registrar_ingreso(
  p_fuente   text,
  p_monto    numeric,
  p_clase    text    default 'extra',
  p_nota     text    default null,
  p_forzar   boolean default false,
  p_dias_min int     default 20,
  p_rotar    boolean default null
)
returns jsonb
language plpgsql as $$
declare
  v_actual   periodos;
  v_hoy      date := hoy_lima();
  v_dias     int;
  v_nuevo    uuid;
  v_sobrante numeric;
  v_rotado   boolean := false;
  v_motivo   text;
  v_id       uuid;
  v_clase    text := lower(coalesce(p_clase, 'extra'));
begin
  if v_clase not in ('sueldo', 'extra', 'retiro') then
    v_clase := 'extra';
  end if;

  select * into v_actual from periodos where cerrado = false limit 1;

  if v_clase = 'sueldo' and coalesce(p_rotar, true) then
    v_dias := case when v_actual.id is null then null
                   else (v_hoy - v_actual.inicio) + 1 end;

    if v_actual.id is null then
      v_nuevo  := abrir_ciclo(v_hoy);
      v_rotado := true;
      v_motivo := 'No había ciclo abierto';

    elsif v_dias < p_dias_min and not p_forzar then
      v_motivo := format(
        'El ciclo lleva %s días (mínimo %s para rotar). El ingreso entró al ciclo actual; manda forzar=true si de verdad cobraste.',
        v_dias, p_dias_min);

    else
      v_sobrante := cerrar_ciclo(v_actual.id, greatest(v_hoy - 1, v_actual.inicio));
      v_nuevo  := abrir_ciclo(v_hoy);
      v_rotado := true;
      v_motivo := format('Ciclo anterior cerrado con %s al ahorro', soles(v_sobrante));
    end if;

  elsif v_clase = 'sueldo' then
    v_motivo := 'Registrado en el ciclo actual sin rotar';
  end if;

  insert into ingresos (fuente, monto, fecha, confirmado, es_retiro, principal, nota)
  values (
    coalesce(nullif(btrim(p_fuente), ''), 'Sin fuente'),
    p_monto, v_hoy, true,
    v_clase = 'retiro', v_clase = 'sueldo', p_nota
  )
  returning id into v_id;

  return jsonb_build_object(
    'ok', true, 'id', v_id, 'clase', v_clase, 'monto', p_monto,
    'rotado', v_rotado, 'sobrante', v_sobrante, 'motivo', v_motivo,
    'periodo_id', ciclo_actual(),
    'mensaje', case
      when v_rotado then format('Ciclo nuevo abierto con %s', soles(p_monto))
      when v_clase = 'retiro' then format('%s retirados del ahorro', soles(p_monto))
      else format('%s registrados', soles(p_monto))
    end,
    'estado', (select to_jsonb(t) from estado_ciclo() t)
  );
end;
$$;
