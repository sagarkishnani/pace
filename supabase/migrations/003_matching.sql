-- ============================================================
-- Matching: de lo que dice el banco a un movimiento con sentido
--
-- Nada de esto depende de cómo lleguen los correos. El Worker
-- inserta en movimientos con lo crudo en `raw`, y acá se resuelve
-- el servicio, el comercio y la categoría.
-- ============================================================

create extension if not exists unaccent;

-- ------------------------------------------------------------
-- Normalización de texto: los bancos escriben sucio
-- '195 PVEA Jockey ' → '195 PVEA JOCKEY'
-- ------------------------------------------------------------
create or replace function txt_norm(p_texto text)
returns text
language sql stable as $$
  select nullif(
    btrim(regexp_replace(upper(unaccent(coalesce(p_texto, ''))), '\s+', ' ', 'g')),
    ''
  );
$$;

-- ------------------------------------------------------------
-- Comercio: el patrón más largo gana
--
-- Así 'DIDI FOOD' le gana a 'DIDI' y el delivery no termina
-- contado como transporte.
-- ------------------------------------------------------------
create or replace function buscar_comercio(p_texto text)
returns comercios
language sql stable as $$
  select c.*
  from comercios c
  where txt_norm(p_texto) like '%' || txt_norm(c.patron) || '%'
  order by length(c.patron) desc
  limit 1;
$$;

-- ------------------------------------------------------------
-- Servicio: por código de usuario cuando el correo lo trae,
-- por cercanía de monto cuando no
--
-- Yape trae el código y ahí el match es exacto. Sin código hay
-- que adivinar por monto, y adivinar mal es peor que no enlazar:
-- si dos servicios quedan a menos de 15% de distancia devuelve
-- ambiguo y el movimiento se queda suelto para que decidas tú.
-- ------------------------------------------------------------
create or replace function buscar_servicio(
  p_codigo  text,
  p_monto   numeric,
  p_empresa text default null
)
returns table (id uuid, ambiguo boolean)
language plpgsql stable as $$
declare
  v_id       uuid;
  v_d1       numeric;
  v_d2       numeric;
begin
  -- 1. Código de usuario: la llave real
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

  -- 2. Empresa, si el correo la trae y es única entre los activos
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

  -- 3. Monto más cercano al estimado
  if p_monto is null then
    return;
  end if;

  select s.id, abs(s.monto_estimado - p_monto)
  into v_id, v_d1
  from servicios s
  where s.activo and s.monto_estimado > 0
  order by abs(s.monto_estimado - p_monto)
  limit 1;

  if v_id is null then
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

-- ------------------------------------------------------------
-- Enriquecimiento: corre antes de guardar el movimiento
--
-- Solo rellena lo que venga nulo. Lo que ya decidiste —una
-- categoría puesta a mano, un enlace corregido— nunca se pisa.
-- ------------------------------------------------------------
create or replace function enriquecer_movimiento()
returns trigger
language plpgsql as $$
declare
  v_com comercios;
  v_srv record;
  v_cat text;
begin
  -- Servicio, si el movimiento todavía no está atado a nada
  if new.servicio_id is null and new.fijo_id is null then
    select * into v_srv
    from buscar_servicio(
      new.raw->>'codigo_usuario',
      new.monto,
      new.raw->>'empresa'
    );

    if v_srv.id is not null and not v_srv.ambiguo then
      new.servicio_id := v_srv.id;
    end if;
  end if;

  -- Comercio normalizado, y su categoría si no traía una
  if new.comercio is not null then
    v_com := buscar_comercio(new.comercio);
    if v_com.patron is not null then
      new.comercio  := v_com.nombre;
      new.categoria := coalesce(new.categoria, v_com.categoria);
    end if;
  end if;

  -- Yape y Plin no dicen a qué comercio le pagaste: el correo trae
  -- un nombre truncado ('El M Anonima C'), inútil por sí solo. La
  -- categoría se aprende de cuando categorizaste a ese destinatario.
  if new.categoria is null and new.tipo in ('yape', 'plin') then
    select d.categoria into v_cat
    from destinatarios d
    where d.clave = txt_norm(new.raw->>'destinatario');
    new.categoria := v_cat;
  end if;

  -- Un fijo o un servicio no es gasto variable, así que no lleva
  -- categoría: si no, aparece en el resumen que solo debe mostrar
  -- la bolsa.
  if new.servicio_id is not null or new.fijo_id is not null then
    new.categoria := null;
  end if;

  return new;
end;
$$;

create trigger tg_enriquecer_movimiento
before insert or update of comercio, raw, servicio_id, fijo_id
on movimientos
for each row execute function enriquecer_movimiento();

-- ------------------------------------------------------------
-- Aprender destinatarios: categorizar un Yape enseña al sistema
--
-- La próxima vez que le pagues a la misma persona, la categoría
-- sale sola.
-- ------------------------------------------------------------
create or replace function aprender_destinatario()
returns trigger
language plpgsql as $$
declare
  v_clave text := txt_norm(new.raw->>'destinatario');
begin
  if new.categoria is not null
     and new.tipo in ('yape', 'plin')
     and v_clave is not null
  then
    insert into destinatarios (clave, alias, categoria)
    values (v_clave, new.raw->>'destinatario', new.categoria)
    on conflict (clave) do update
      set categoria = excluded.categoria,
          alias     = coalesce(destinatarios.alias, excluded.alias);
  end if;
  return null;
end;
$$;

create trigger tg_aprender_destinatario
after update of categoria on movimientos
for each row
when (new.categoria is distinct from old.categoria)
execute function aprender_destinatario();

-- ------------------------------------------------------------
-- Documentos: boletas y recibos se enlazan, nunca crean gasto
--
-- Un documento sin movimiento es un gasto que el banco todavía no
-- reportó, o uno de Interbank que no registraste. Los dos casos
-- valen y no hay que inventarles un movimiento.
-- ------------------------------------------------------------
create or replace function enlazar_documentos(p_dias int default 3)
returns int
language plpgsql as $$
declare
  d           record;
  v_candidato uuid;
  v_cuantos   int;
  v_enlazados int := 0;
begin
  for d in
    select * from documentos
    where movimiento_id is null and estado <> 'revisar'
  loop
    -- array_agg y no min(): uuid no tiene agregado de mínimo
    select count(*), (array_agg(m.id))[1]
    into v_cuantos, v_candidato
    from movimientos m
    where m.monto  = d.monto
      and m.moneda = d.moneda
      and m.fecha between d.fecha - make_interval(days => p_dias)
                      and d.fecha + make_interval(days => p_dias)
      and not exists (
        select 1 from documentos x where x.movimiento_id = m.id
      );

    if v_cuantos = 1 then
      update documentos
      set movimiento_id = v_candidato, estado = 'enlazado'
      where id = d.id;
      v_enlazados := v_enlazados + 1;

    elsif v_cuantos > 1 then
      -- Dos movimientos del mismo monto el mismo día: elige tú
      update documentos set estado = 'revisar' where id = d.id;
    end if;
  end loop;

  return v_enlazados;
end;
$$;

-- ------------------------------------------------------------
-- Recibos que se están pasando
--
-- Si venció y no llegó ningún correo de pago, probablemente se te
-- está pasando. Esto es lo único del sistema que avisa por algo
-- que NO ocurrió.
-- ------------------------------------------------------------
create or replace function recibos_pendientes()
returns table (
  servicio   text,
  empresa    text,
  estimado   numeric,
  vence_el   date,
  dias_atraso int
)
language sql stable as $$
  select s.nombre, s.empresa, s.monto_estimado, s.vence_el,
         (current_date - s.vence_el)::int
  from servicios s
  where s.activo
    and s.vence_el is not null
    and s.vence_el < current_date
    and not exists (
      select 1 from movimientos m
      where m.servicio_id = s.id
        and m.periodo_id  = ciclo_actual()
    )
  order by s.vence_el;
$$;

-- ------------------------------------------------------------
-- Lo que quedó sin resolver, para la reconciliación semanal
-- ------------------------------------------------------------
create or replace function sin_resolver()
returns table (
  id        uuid,
  fecha     timestamptz,
  monto     numeric,
  banco     text,
  tipo      text,
  comercio  text,
  origen    text,
  motivo    text
)
language sql stable as $$
  select m.id, m.fecha, m.monto, m.banco, m.tipo, m.comercio, m.origen,
         case
           when m.categoria is null then 'sin categoría'
           when not m.confirmado    then 'sin confirmar'
         end
  from movimientos m
  where m.periodo_id = ciclo_actual()
    and m.fijo_id is null
    and m.servicio_id is null
    and (m.categoria is null or not m.confirmado)
  order by m.fecha desc;
$$;
