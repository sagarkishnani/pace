-- ============================================================
-- Control de gastos — esquema base
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- Ciclos: van de cobro a cobro, no de mes calendario
-- ------------------------------------------------------------
create table periodos (
  id        uuid primary key default gen_random_uuid(),
  inicio    date not null,
  fin       date not null,
  etiqueta  text,
  cerrado   boolean not null default false,
  sobrante  numeric(12,2),
  creado_en timestamptz not null default now(),
  constraint periodo_rango_valido check (fin >= inicio)
);

-- Solo puede haber un ciclo abierto a la vez
create unique index ux_periodo_abierto
  on periodos ((true)) where cerrado = false;

create index ix_periodo_inicio on periodos (inicio desc);

-- ------------------------------------------------------------
-- Configuración: se congela al abrir el ciclo, editable con rastro
-- ------------------------------------------------------------
create table config_ciclo (
  periodo_id      uuid primary key references periodos(id) on delete cascade,
  pct_ahorro      numeric(5,2)  not null default 30.00,
  pct_colchon     numeric(5,2)  not null default 0.00,
  monto_esposa    numeric(12,2) not null default 0.00,
  umbral_ambar    numeric(5,2)  not null default 1.00,
  umbral_rojo     numeric(5,2)  not null default 1.20,
  caida_permitido numeric(5,2)  not null default 0.40,
  dias_min_alerta int           not null default 5,
  dia_inicio_eval int           not null default 5,
  estado_alerta   text          not null default 'verde',
  ultima_alerta   timestamptz,
  editado_en      timestamptz,
  nota_edicion    text,
  constraint estado_valido check (estado_alerta in ('verde','ambar','rojo'))
);

-- ------------------------------------------------------------
-- Ingresos: filas independientes, no un campo fijo
-- ------------------------------------------------------------
create table ingresos (
  id          uuid primary key default gen_random_uuid(),
  periodo_id  uuid references periodos(id) on delete set null,
  fuente      text not null,
  monto       numeric(12,2) not null,
  fecha       date not null,
  confirmado  boolean not null default false,
  es_retiro   boolean not null default false,  -- sacar de ahorros no es ingreso
  principal   boolean not null default false,  -- dispara la apertura del ciclo
  nota        text,
  creado_en   timestamptz not null default now()
);

create index ix_ingresos_periodo on ingresos (periodo_id);

-- ------------------------------------------------------------
-- Fijos: alquiler, suscripciones. Fuera del pool variable.
-- ------------------------------------------------------------
create table fijos (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  monto      numeric(12,2) not null,
  moneda     text not null default 'PEN',
  dia_aprox  int,
  activo     boolean not null default true,
  nota       text
);

-- ------------------------------------------------------------
-- Servicios: monto variable, se identifican por codigo_usuario
-- ------------------------------------------------------------
create table servicios (
  id             uuid primary key default gen_random_uuid(),
  nombre         text not null,
  empresa        text,
  codigo_usuario text unique,
  monto_estimado numeric(12,2) not null default 0,
  dia_aprox      int,
  vence_el       date,
  activo         boolean not null default true
);

-- ------------------------------------------------------------
-- Comercios: normaliza nombres sucios del banco
-- ------------------------------------------------------------
create table comercios (
  patron    text primary key,          -- '195 PVEA', 'TOTTUS', 'RAPPI'
  nombre    text not null,
  categoria text not null
);

-- Destinatarios recurrentes de Yape/Plin: la categoría se aprende
create table destinatarios (
  clave     text primary key,          -- nombre truncado o celular
  alias     text,
  categoria text
);

-- ------------------------------------------------------------
-- Movimientos: plata que salió de una cuenta
-- ------------------------------------------------------------
create table movimientos (
  id            uuid primary key default gen_random_uuid(),
  periodo_id    uuid references periodos(id) on delete set null,
  fecha         timestamptz not null,
  monto         numeric(12,2) not null,
  moneda        text not null default 'PEN',
  comercio      text,
  categoria     text,
  tarjeta_4d    text,
  banco         text not null,
  tipo          text not null,
  origen        text not null,
  confirmado    boolean not null default false,
  fijo_id       uuid references fijos(id) on delete set null,
  servicio_id   uuid references servicios(id) on delete set null,
  ref_operacion text,
  hash_origen   text,
  raw           jsonb,
  creado_en     timestamptz not null default now(),

  constraint tipo_valido check (tipo in (
    'debito','credito','yape','plin','efectivo',
    'recarga_monedero','consumo_monedero'
  )),
  constraint origen_valido check (origen in ('email','shortcut','manual'))
);

-- Deduplicación: por referencia del banco cuando existe, por hash si no
create unique index ux_mov_ref  on movimientos (banco, ref_operacion)
  where ref_operacion is not null;
create unique index ux_mov_hash on movimientos (hash_origen)
  where hash_origen is not null;

create index ix_mov_periodo on movimientos (periodo_id);
create index ix_mov_fecha   on movimientos (fecha desc);
create index ix_mov_match   on movimientos (monto, moneda, fecha);

-- ------------------------------------------------------------
-- Documentos: recibos y boletas. Nunca crean un movimiento.
-- ------------------------------------------------------------
create table documentos (
  id            uuid primary key default gen_random_uuid(),
  movimiento_id uuid references movimientos(id) on delete set null,
  emisor        text not null,
  monto         numeric(12,2) not null,
  moneda        text not null default 'PEN',
  fecha         timestamptz not null,
  categoria     text,
  estado        text not null default 'pendiente',
  hash_origen   text unique,
  raw           jsonb,
  creado_en     timestamptz not null default now(),

  constraint doc_estado_valido check (estado in ('pendiente','enlazado','revisar'))
);

create index ix_doc_match on documentos (monto, moneda, fecha)
  where movimiento_id is null;

-- ------------------------------------------------------------
-- RLS: todo pasa por service_role (Worker y Edge Functions).
-- Sin políticas públicas, la anon key no lee nada.
-- ------------------------------------------------------------
alter table periodos      enable row level security;
alter table config_ciclo  enable row level security;
alter table ingresos      enable row level security;
alter table fijos         enable row level security;
alter table servicios     enable row level security;
alter table comercios     enable row level security;
alter table destinatarios enable row level security;
alter table movimientos   enable row level security;
alter table documentos    enable row level security;
