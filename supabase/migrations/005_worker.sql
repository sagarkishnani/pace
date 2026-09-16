-- ============================================================
-- Ajustes que salieron de ver los correos reales
--
-- Dos cosas que el diseño no había previsto:
--
-- 1. Yape P2P trae los últimos dígitos del celular del
--    beneficiario además del nombre truncado. El nombre solo
--    ("Antuanet Var*") se presta a colisiones; con el sufijo la
--    llave es estable. El Worker manda la llave en `destinatario`
--    y el nombre legible en `destinatario_nombre`.
--
-- 2. El Worker no debería tener que preguntar cuál es el ciclo
--    abierto antes de cada insert. Lo resuelve la base.
-- ============================================================

-- ------------------------------------------------------------
-- El respaldo por monto era demasiado suelto
--
-- Con un solo servicio activo, cualquier movimiento encontraba
-- candidato y ninguno resultaba ambiguo: un consumo de S/ 78.29
-- en Tottus terminaba enlazado al internet de S/ 119. Un enlace
-- equivocado saca el gasto de la bolsa sin avisar, que es la
-- peor falla posible acá.
--
-- Ahora el respaldo pide dos cosas: que el movimiento pueda ser
-- un pago de servicio (Yape o Plin — un consumo con tarjeta
-- nunca lo es) y que el monto caiga dentro del 15% del estimado.
-- Fuera de eso no enlaza y el movimiento sale en sin_resolver().
-- ------------------------------------------------------------
drop function if exists buscar_servicio(text, numeric, text);

create function buscar_servicio(
  p_codigo  text,
  p_monto   numeric,
  p_empresa text default null,
  p_tipo    text default null
)
returns table (id uuid, ambiguo boolean)
language plpgsql stable as $$
declare
  v_id uuid;
  v_d1 numeric;
  v_d2 numeric;
  v_est numeric;
begin
  -- 1. Código de usuario: la llave real, siempre gana
  if txt_norm(p_codigo) is not null then
    select s.id into v_id
    from servicios s
    where txt_norm(s.codigo_usuario) = txt_norm(p_codigo)
    limit 1;

    if v_id is not null then
      return query select v_id, false;
      return;
    end if;
  end if;

  -- 2. Empresa exacta entre los activos
  if txt_norm(p_empresa) is not null then
    select s.id into v_id
    from servicios s
    where s.activo and txt_norm(s.empresa) = txt_norm(p_empresa)
    limit 1;

    if v_id is not null then
      return query select v_id, false;
      return;
    end if;
  end if;

  -- 3. Monto cercano, solo para lo que puede ser un pago de servicio
  if p_monto is null or coalesce(p_tipo, '') not in ('yape', 'plin') then
    return;
  end if;

  select s.id, abs(s.monto_estimado - p_monto), s.monto_estimado
  into v_id, v_d1, v_est
  from servicios s
  where s.activo and s.monto_estimado > 0
  order by abs(s.monto_estimado - p_monto)
  limit 1;

  -- Lejos del estimado: no es ese servicio
  if v_id is null or v_d1 > v_est * 0.15 then
    return;
  end if;

  select abs(s.monto_estimado - p_monto) into v_d2
  from servicios s
  where s.activo and s.monto_estimado > 0 and s.id <> v_id
  order by abs(s.monto_estimado - p_monto)
  limit 1;

  -- Dos candidatos igual de cerca: mejor no enlazar nada
  return query select
    v_id,
    v_d2 is not null and v_d2 < greatest(v_d1, 0.01) * 1.15;
end;
$$;

create or replace function enriquecer_movimiento()
returns trigger
language plpgsql as $$
declare
  v_com comercios;
  v_srv record;
  v_cat text;
begin
  -- El ciclo abierto, si el que inserta no lo especificó. Cuando no
  -- hay ninguno abierto queda nulo y abrir_ciclo() lo reencola.
  if new.periodo_id is null then
    new.periodo_id := ciclo_actual();
  end if;

  if new.servicio_id is null and new.fijo_id is null then
    select * into v_srv
    from buscar_servicio(
      new.raw->>'codigo_usuario',
      new.monto,
      new.raw->>'empresa',
      new.tipo
    );

    if v_srv.id is not null and not v_srv.ambiguo then
      new.servicio_id := v_srv.id;
    end if;
  end if;

  if new.comercio is not null then
    v_com := buscar_comercio(new.comercio);
    if v_com.patron is not null then
      new.comercio  := v_com.nombre;
      new.categoria := coalesce(new.categoria, v_com.categoria);
    end if;
  end if;

  if new.categoria is null and new.tipo in ('yape', 'plin') then
    select d.categoria into v_cat
    from destinatarios d
    where d.clave = txt_norm(new.raw->>'destinatario');
    new.categoria := v_cat;
  end if;

  if new.servicio_id is not null or new.fijo_id is not null then
    new.categoria := null;
  end if;

  return new;
end;
$$;

-- El alias guarda el nombre legible, no la llave con el sufijo
create or replace function aprender_destinatario()
returns trigger
language plpgsql as $$
declare
  v_clave  text := txt_norm(new.raw->>'destinatario');
  v_nombre text := coalesce(new.raw->>'destinatario_nombre', new.raw->>'destinatario');
begin
  if new.categoria is not null
     and new.tipo in ('yape', 'plin')
     and v_clave is not null
  then
    insert into destinatarios (clave, alias, categoria)
    values (v_clave, v_nombre, new.categoria)
    on conflict (clave) do update
      set categoria = excluded.categoria,
          alias     = coalesce(destinatarios.alias, excluded.alias);
  end if;
  return null;
end;
$$;

-- El trigger tiene que mirar periodo_id también, si no un insert
-- que solo trae periodo_id nulo no dispara el relleno.
drop trigger if exists tg_enriquecer_movimiento on movimientos;
create trigger tg_enriquecer_movimiento
before insert or update of comercio, raw, servicio_id, fijo_id, periodo_id
on movimientos
for each row execute function enriquecer_movimiento();

-- ------------------------------------------------------------
-- WIN Internet: el servicio real que apareció en los correos
-- ------------------------------------------------------------
insert into comercios (patron, nombre, categoria) values
  ('WIN INTERNET', 'WIN Internet', 'otro')
on conflict (patron) do nothing;

-- ------------------------------------------------------------
-- Los ingresos también necesitan ciclo
--
-- abrir_ciclo() reencola los que quedaron sueltos, pero uno
-- insertado después de abrir el ciclo se quedaba en null y
-- simplemente no contaba. El ingreso es el número del que cuelga
-- todo lo demás: un ingreso que no suma deja la bolsa en negativo
-- y el ciclo en rojo sin que nada parezca roto.
-- ------------------------------------------------------------
create or replace function asignar_ciclo_ingreso()
returns trigger
language plpgsql as $$
begin
  if new.periodo_id is null then
    new.periodo_id := ciclo_actual();
  end if;
  return new;
end;
$$;

create trigger tg_asignar_ciclo_ingreso
before insert on ingresos
for each row execute function asignar_ciclo_ingreso();
