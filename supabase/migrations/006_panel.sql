-- ============================================================
-- Débito vs crédito, panel y alertas
--
-- Tres cosas que la fase 3 necesita y no estaban:
--
-- 1. Pagar la tarjeta de crédito no es un gasto nuevo. El consumo
--    ya contó el día que pasaste la tarjeta; si el pago del
--    estado de cuenta contara también, los mismos soles salen
--    dos veces de la bolsa. Entra el tipo `pago_tarjeta`, que se
--    registra pero no gasta — mismo criterio que
--    `consumo_monedero`.
--
-- 2. El día lo decide Lima, no UTC. `current_date` en un servidor
--    UTC cambia a las 7 de la noche de Lima: un gasto de la cena
--    caía en el día siguiente y el contador de días del ciclo se
--    adelantaba toda la tarde. Justo el número que más se mira.
--
-- 3. El panel y las alertas leen de acá, no recalculan nada.
-- ============================================================

-- ------------------------------------------------------------
-- Hoy, en Lima
-- ------------------------------------------------------------
create or replace function hoy_lima()
returns date
language sql stable as $$
  select (now() at time zone 'America/Lima')::date;
$$;

-- Formato de plata para los mensajes de alerta
create or replace function soles(p_monto numeric)
returns text
language sql immutable as $$
  select 'S/ ' || to_char(coalesce(p_monto, 0), 'FM9,999,990.00');
$$;

-- ------------------------------------------------------------
-- El pago de la tarjeta es un movimiento, pero no es gasto
-- ------------------------------------------------------------
alter table movimientos drop constraint if exists tipo_valido;
alter table movimientos add constraint tipo_valido check (tipo in (
  'debito','credito','yape','plin','efectivo',
  'recarga_monedero','consumo_monedero','pago_tarjeta'
));

-- ------------------------------------------------------------
-- Un ciclo de solo medición no necesita el truco de
-- dia_inicio_eval = 99
-- ------------------------------------------------------------
alter table config_ciclo
  add column if not exists alertas_activas boolean not null default true;

-- ------------------------------------------------------------
-- estado_ciclo(): mismos números, tres cambios
--
--   · el día sale de hoy_lima()
--   · pago_tarjeta sale del gasto
--   · se separa lo que ya salió de la cuenta de lo que va a
--     llegar como estado de cuenta
--
-- `gastado` sigue contando el crédito el día que lo pasas, no el
-- día que lo pagas. Es deliberado: la pregunta del proyecto es
-- cuánto margen queda para ahorrar, y un consumo a crédito ya se
-- comió ese margen aunque la plata siga en la cuenta. Contarlo
-- recién al pagar el estado de cuenta deja el ciclo en verde
-- mientras la tarjeta se llena.
-- ------------------------------------------------------------
drop function if exists estado_ciclo(uuid);

create function estado_ciclo(p_periodo uuid default null)
returns table (
  periodo_id        uuid,
  etiqueta          text,
  inicio            date,
  fin               date,
  dia_actual        int,
  dias_ciclo        int,
  dias_restantes    int,
  ingreso           numeric,
  retiros           numeric,
  ahorro            numeric,
  ahorro_colchon    numeric,
  ahorro_objetivo   numeric,
  esposa            numeric,
  fijos_total       numeric,
  servicios_total   numeric,
  fijos_pendientes  numeric,
  bolsa             numeric,
  gastado           numeric,
  gastado_credito   numeric,
  gastado_contado   numeric,
  disponible        numeric,
  permitido_dia     numeric,
  ritmo             numeric,
  proyeccion        numeric,
  ratio             numeric,
  estado            text
)
language plpgsql stable as $$
declare
  p          record;
  c          record;
  v_hoy      date;
  v_dia      int;
  v_dias     int;
  v_rest     int;
  v_ing      numeric := 0;
  v_ret      numeric := 0;
  v_aho      numeric := 0;
  v_fij      numeric := 0;
  v_srv      numeric := 0;
  v_fij_pend numeric := 0;
  v_srv_pend numeric := 0;
  v_bolsa    numeric := 0;
  v_gasto    numeric := 0;
  v_cred     numeric := 0;
  v_cont     numeric := 0;
  v_disp     numeric := 0;
  v_perm     numeric := 0;
  v_ritmo    numeric := 0;
  v_proy     numeric := 0;
  v_ratio    numeric := 0;
  v_estado   text    := 'verde';
begin
  select * into p from periodos
  where id = coalesce(p_periodo, ciclo_actual());
  if not found then return; end if;

  select * into c from config_ciclo where config_ciclo.periodo_id = p.id;

  v_hoy  := hoy_lima();
  v_dias := (p.fin - p.inicio) + 1;
  v_dia  := greatest(least((v_hoy - p.inicio) + 1, v_dias), 1);
  v_rest := greatest((p.fin - v_hoy) + 1, 1);

  select coalesce(sum(monto) filter (where not es_retiro), 0),
         coalesce(sum(monto) filter (where es_retiro), 0)
  into v_ing, v_ret
  from ingresos
  where ingresos.periodo_id = p.id and confirmado;

  v_aho := round(v_ing * c.pct_ahorro / 100, 2);

  select coalesce(sum(monto), 0) into v_fij
  from fijos where activo;

  select coalesce(sum(monto_estimado), 0) into v_srv
  from servicios where activo;

  select coalesce(sum(f.monto), 0) into v_fij_pend
  from fijos f
  where f.activo
    and not exists (
      select 1 from movimientos m
      where m.fijo_id = f.id and m.periodo_id = p.id
    );

  select coalesce(sum(s.monto_estimado), 0) into v_srv_pend
  from servicios s
  where s.activo
    and not exists (
      select 1 from movimientos m
      where m.servicio_id = s.id and m.periodo_id = p.id
    );

  v_bolsa := v_ing + v_ret - v_aho - c.monto_esposa - v_fij - v_srv;

  -- Gasto variable: fuera lo atado a un fijo o servicio, fuera el
  -- consumo de monedero (ya pagado al recargar) y fuera el pago
  -- de tarjeta (ya contado al pasarla).
  select coalesce(sum(monto), 0),
         coalesce(sum(monto) filter (where tipo = 'credito'), 0),
         coalesce(sum(monto) filter (where tipo <> 'credito'), 0)
  into v_gasto, v_cred, v_cont
  from movimientos
  where movimientos.periodo_id = p.id
    and fijo_id is null
    and servicio_id is null
    and tipo not in ('consumo_monedero', 'pago_tarjeta');

  v_disp  := v_bolsa - v_gasto;
  v_perm  := round(v_disp / v_rest, 2);
  v_ritmo := round(v_gasto / v_dia, 2);
  v_proy  := round(v_ritmo * v_dias, 2);
  v_ratio := case when v_bolsa > 0 then round(v_proy / v_bolsa, 4) else 0 end;

  if v_dia < c.dia_inicio_eval then
    v_estado := 'verde';
  elsif v_ratio > c.umbral_rojo
        or (v_perm > 0 and v_disp / greatest(v_perm, 0.01) < c.dias_min_alerta)
        or v_disp < 0 then
    v_estado := 'rojo';
  elsif v_ratio > c.umbral_ambar then
    v_estado := 'ambar';
  else
    v_estado := 'verde';
  end if;

  return query select
    p.id, p.etiqueta, p.inicio, p.fin, v_dia, v_dias, v_rest,
    v_ing, v_ret, v_aho,
    round(v_aho * c.pct_colchon / 100, 2),
    round(v_aho * (100 - c.pct_colchon) / 100, 2),
    c.monto_esposa, v_fij, v_srv, v_fij_pend + v_srv_pend,
    v_bolsa, v_gasto, v_cred, v_cont,
    v_disp, v_perm, v_ritmo, v_proy, v_ratio, v_estado;
end;
$$;

-- recibos_pendientes() también tiene que mirar el día de Lima
create or replace function recibos_pendientes()
returns table (
  servicio    text,
  empresa     text,
  estimado    numeric,
  vence_el    date,
  dias_atraso int
)
language sql stable as $$
  select s.nombre, s.empresa, s.monto_estimado, s.vence_el,
         (hoy_lima() - s.vence_el)::int
  from servicios s
  where s.activo
    and s.vence_el is not null
    and s.vence_el < hoy_lima()
    and not exists (
      select 1 from movimientos m
      where m.servicio_id = s.id
        and m.periodo_id  = ciclo_actual()
    )
  order by s.vence_el;
$$;

-- ============================================================
-- panel(): todo lo que el dashboard necesita, en una llamada
--
-- Un solo RPC y no ocho. El panel se abre desde el celular con
-- señal de calle; ocho viajes es medio segundo cada uno y un
-- estado a medio cargar. Además mantiene la regla de la casa:
-- los números salen de estado_ciclo(), nadie los recalcula
-- en el cliente.
-- ============================================================
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

  -- Gasto variable por categoría
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

  -- Por método: acá se ve cuánto del ciclo llega después como
  -- estado de cuenta y cuánto ya salió de la cuenta
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

  -- Día a día contra la línea ideal (bolsa repartida parejo).
  -- Es la curva que dice si vas adelantado o no; el número del
  -- día suelto no dice nada.
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

  -- Últimos movimientos, ya enriquecidos
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

  -- Fijos y servicios: lo que falta pagar del ciclo
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

  -- Ciclos cerrados: la tendencia, que es lo que de verdad dice
  -- si estás acercándote a la meta
  out := out || jsonb_build_object('historial', (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.inicio), '[]'::jsonb)
    from (
      select pr.id, pr.etiqueta, pr.inicio, pr.fin, pr.sobrante,
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
-- registrar_ingreso(): el atajo de ingresos entra por acá
--
-- Tres clases, y solo una toca el ciclo:
--
--   sueldo  el ingreso principal. Cierra el ciclo anterior (con
--           lo que barre al ahorro) y abre uno nuevo desde hoy.
--           Eso es lo que significa "de cobro a cobro": el ciclo
--           lo mueve la plata, no el calendario.
--   extra   cualquier otro ingreso del ciclo en curso.
--   retiro  sacar de ahorros. Suma a la caja pero no al ahorro,
--           si no el motor "ahorraría" el 30% de plata que
--           acabas de sacar del ahorro.
--
-- Rotar de ciclo barre el sobrante y no se deshace con un toque,
-- así que un `sueldo` antes de p_dias_min no rota: registra el
-- ingreso en el ciclo actual y lo dice. Perder un ingreso sería
-- peor que no rotar — es el número del que cuelga todo lo demás.
-- ============================================================
create or replace function registrar_ingreso(
  p_fuente   text,
  p_monto    numeric,
  p_clase    text    default 'extra',
  p_nota     text    default null,
  p_forzar   boolean default false,
  p_dias_min int     default 20
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

  if v_clase = 'sueldo' then
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
      -- El ciclo anterior termina la víspera del cobro
      v_sobrante := cerrar_ciclo(
        v_actual.id,
        greatest(v_hoy - 1, v_actual.inicio)
      );
      v_nuevo  := abrir_ciclo(v_hoy);
      v_rotado := true;
      v_motivo := format('Ciclo anterior cerrado con %s al ahorro', soles(v_sobrante));
    end if;
  end if;

  insert into ingresos (fuente, monto, fecha, confirmado, es_retiro, principal, nota)
  values (
    coalesce(nullif(btrim(p_fuente), ''), 'Sin fuente'),
    p_monto,
    v_hoy,
    true,
    v_clase = 'retiro',
    v_clase = 'sueldo',
    p_nota
  )
  returning id into v_id;

  return jsonb_build_object(
    'ok',         true,
    'id',         v_id,
    'clase',      v_clase,
    'monto',      p_monto,
    'rotado',     v_rotado,
    'sobrante',   v_sobrante,
    'motivo',     v_motivo,
    'periodo_id', ciclo_actual(),
    'estado',     (select to_jsonb(t) from estado_ciclo() t)
  );
end;
$$;

-- ============================================================
-- evaluar_alerta(): decide si hay algo que avisar
--
-- La decisión vive acá y no en el endpoint, por la misma razón
-- que los números: una sola fuente. El endpoint solo hace el
-- POST al webhook con lo que esta función devuelva.
--
-- Avisa cuando el estado SUBE (verde→ámbar→rojo), cuando sigue
-- en rojo y ya pasó un día del último aviso, y cuando sale de
-- rojo. No avisa al bajar de ámbar a verde: eso es el sistema
-- funcionando, y una notificación que no pide nada enseña a
-- ignorar las que sí.
-- ============================================================
create or replace function evaluar_alerta(
  p_periodo uuid  default null,
  p_modo    text  default 'cambio'   -- 'cambio' | 'diario'
)
returns table (
  notificar boolean,
  estado    text,
  anterior  text,
  titulo    text,
  cuerpo    text
)
language plpgsql as $$
declare
  e        record;
  c        record;
  v_prev   text;
  v_not    boolean := false;
  v_tit    text;
  v_cue    text;
  v_rank   jsonb := '{"verde":0,"ambar":1,"rojo":2}'::jsonb;
  v_icono  text;
  v_pend   int;
begin
  select * into e from estado_ciclo(p_periodo);
  if not found then return; end if;

  select * into c from config_ciclo where config_ciclo.periodo_id = e.periodo_id;
  v_prev := coalesce(c.estado_alerta, 'verde');

  if not c.alertas_activas then
    update config_ciclo set estado_alerta = e.estado
    where config_ciclo.periodo_id = e.periodo_id;
    return query select false, e.estado, v_prev, null::text, null::text;
    return;
  end if;

  if p_modo = 'diario' then
    v_not := true;
  elsif (v_rank->>e.estado)::int > (v_rank->>v_prev)::int then
    v_not := true;
  elsif e.estado = 'rojo'
        and (c.ultima_alerta is null or c.ultima_alerta < now() - interval '20 hours') then
    v_not := true;
  elsif v_prev = 'rojo' and e.estado = 'verde' then
    v_not := true;
  end if;

  v_icono := case e.estado when 'rojo' then '🔴' when 'ambar' then '🟠' else '🟢' end;

  if e.estado = 'rojo' then
    v_tit := v_icono || ' A este ritmo no llegas a fin de ciclo';
  elsif e.estado = 'ambar' then
    v_tit := v_icono || ' El ritmo se pasó del plan · hoy ' || soles(e.permitido_dia);
  elsif v_prev = 'rojo' then
    v_tit := v_icono || ' Saliste de rojo · hoy ' || soles(e.permitido_dia);
  else
    v_tit := v_icono || ' Hoy puedes gastar ' || soles(e.permitido_dia);
  end if;

  v_cue := format(
    E'Día %s de %s · quedan %s días\nBolsa %s · gastado %s · queda %s\nVienes gastando %s al día; el plan es %s.',
    e.dia_actual, e.dias_ciclo, e.dias_restantes,
    soles(e.bolsa), soles(e.gastado), soles(e.disponible),
    soles(e.ritmo), soles(e.permitido_dia)
  );

  if e.gastado_credito > 0 then
    v_cue := v_cue || E'\nDe eso, ' || soles(e.gastado_credito)
             || ' llega después como estado de cuenta.';
  end if;

  if e.fijos_pendientes > 0 then
    v_cue := v_cue || E'\nFaltan pagar ' || soles(e.fijos_pendientes)
             || ' de fijos y servicios (ya están fuera de la bolsa).';
  end if;

  select count(*)::int into v_pend from sin_resolver();
  if v_pend > 0 then
    v_cue := v_cue || format(E'\n%s movimientos sin resolver.', v_pend);
  end if;

  if v_not then
    update config_ciclo
    set estado_alerta = e.estado, ultima_alerta = now()
    where config_ciclo.periodo_id = e.periodo_id;
  else
    update config_ciclo
    set estado_alerta = e.estado
    where config_ciclo.periodo_id = e.periodo_id;
  end if;

  return query select v_not, e.estado, v_prev, v_tit, v_cue;
end;
$$;
