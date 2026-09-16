-- ============================================================
-- Ciclos: apertura, cierre y cálculo de estado
-- ============================================================

-- ------------------------------------------------------------
-- Ciclo abierto actual
-- ------------------------------------------------------------
create or replace function ciclo_actual()
returns uuid
language sql stable as $$
  select id from periodos where cerrado = false limit 1;
$$;

-- ------------------------------------------------------------
-- Abrir ciclo. Copia la config del anterior si existe.
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
  from periodos order by inicio desc limit 1;

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

  -- Reencola lo que quedó sin ciclo
  update ingresos    set periodo_id = v_nuevo where periodo_id is null;
  update movimientos set periodo_id = v_nuevo where periodo_id is null;

  return v_nuevo;
end;
$$;

-- ------------------------------------------------------------
-- Cerrar ciclo: barre el sobrante al ahorro
-- ------------------------------------------------------------
create or replace function cerrar_ciclo(
  p_periodo uuid,
  p_fin     date default null
)
returns numeric
language plpgsql as $$
declare
  v_sobrante numeric(12,2);
begin
  select disponible into v_sobrante from estado_ciclo(p_periodo);

  update periodos
  set cerrado  = true,
      fin      = coalesce(p_fin, fin),
      sobrante = greatest(coalesce(v_sobrante, 0), 0)
  where id = p_periodo;

  return greatest(coalesce(v_sobrante, 0), 0);
end;
$$;

-- ------------------------------------------------------------
-- Estado del ciclo: la única fuente de los números
--
-- Los fijos y servicios se separan del pool variable desde el
-- inicio, así el alquiler del día 1 no dispara la proyección.
-- ------------------------------------------------------------
create or replace function estado_ciclo(p_periodo uuid default null)
returns table (
  periodo_id        uuid,
  etiqueta          text,
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
  fijos_pendientes  numeric,
  bolsa             numeric,
  gastado           numeric,
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
  v_dia      int;
  v_dias     int;
  v_rest     int;
  v_ing      numeric := 0;
  v_ret      numeric := 0;
  v_aho      numeric := 0;
  v_fij      numeric := 0;
  v_fij_pend numeric := 0;
  v_srv_pend numeric := 0;
  v_bolsa    numeric := 0;
  v_gasto    numeric := 0;
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

  v_dias := (p.fin - p.inicio) + 1;
  v_dia  := greatest(least((current_date - p.inicio) + 1, v_dias), 1);
  v_rest := greatest((p.fin - current_date) + 1, 1);

  -- Ingresos confirmados, separando retiros de ahorros
  select coalesce(sum(monto) filter (where not es_retiro), 0),
         coalesce(sum(monto) filter (where es_retiro), 0)
  into v_ing, v_ret
  from ingresos
  where ingresos.periodo_id = p.id and confirmado;

  v_aho := round(v_ing * c.pct_ahorro / 100, 2);

  -- Fijos activos del ciclo, y cuáles siguen sin pagarse
  select coalesce(sum(monto), 0) into v_fij
  from fijos where activo;

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

  -- La bolsa es solo gasto variable: fijos y servicios ya están fuera
  v_bolsa := v_ing + v_ret - v_aho - c.monto_esposa
             - v_fij
             - (select coalesce(sum(monto_estimado), 0) from servicios where activo);

  -- Gasto variable: excluye lo atado a un fijo o servicio,
  -- y los consumos de monedero (ya se pagaron al recargar)
  select coalesce(sum(monto), 0) into v_gasto
  from movimientos
  where movimientos.periodo_id = p.id
    and fijo_id is null
    and servicio_id is null
    and tipo <> 'consumo_monedero';

  v_disp  := v_bolsa - v_gasto;
  v_perm  := round(v_disp / v_rest, 2);
  v_ritmo := round(v_gasto / v_dia, 2);
  v_proy  := round(v_ritmo * v_dias, 2);
  v_ratio := case when v_bolsa > 0 then round(v_proy / v_bolsa, 4) else 0 end;

  -- Antes del día de arranque la proyección es ruido
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
    p.id, p.etiqueta, v_dia, v_dias, v_rest,
    v_ing, v_ret, v_aho,
    round(v_aho * c.pct_colchon / 100, 2),
    round(v_aho * (100 - c.pct_colchon) / 100, 2),
    c.monto_esposa, v_fij, v_fij_pend + v_srv_pend,
    v_bolsa, v_gasto, v_disp, v_perm, v_ritmo, v_proy, v_ratio, v_estado;
end;
$$;

-- ------------------------------------------------------------
-- Servicios: el estimado sigue el promedio de los últimos 3 pagos
-- ------------------------------------------------------------
create or replace function recalcular_estimados()
returns void
language sql as $$
  update servicios s
  set monto_estimado = sub.promedio
  from (
    select servicio_id, round(avg(monto), 2) as promedio
    from (
      select servicio_id, monto,
             row_number() over (partition by servicio_id order by fecha desc) as n
      from movimientos where servicio_id is not null
    ) t
    where n <= 3
    group by servicio_id
  ) sub
  where s.id = sub.servicio_id;
$$;
