# pace

Control de gastos personal. Sabe cuánto puedes gastar **hoy** para llegar a fin de ciclo
con el ahorro intacto, y te avisa cuando el ritmo de gasto se sale de rango.

No es un presupuesto de mes calendario: el ciclo va **de cobro a cobro**, que es como
funciona la plata de verdad.

## Cómo funciona

```
ingresos confirmados
  − ahorro (% configurable)
  − monto de la esposa
  − fijos (alquiler, suscripciones)
  − servicios estimados (luz, internet, celular)
  ─────────────────────────────────────────────
  = bolsa            ← solo gasto variable

  bolsa − gastado    = disponible
  disponible / días restantes = permitido por día
```

Los fijos y los servicios salen del pool desde el día 1, así el alquiler no hace ver el
ciclo en rojo apenas empieza.

Cada gasto entra por una de dos vías:

- **Correo** (automático) — BCP tarjeta, Yape servicios, Yape P2P, Plin, recibos de
  comercio. Pendiente: es la fase 2.
- **Atajo de iOS** (manual) — Interbank y efectivo. Interbank no tiene canal de correo,
  así que es el único gasto que hay que registrar a mano.

El estado del ciclo se calcula en Postgres (`estado_ciclo()`) y devuelve verde, ámbar o
rojo según la proyección de gasto contra la bolsa.

## Estructura

```
supabase/
  migrations/001_schema.sql    tablas, índices, RLS
  migrations/002_ciclos.sql    abrir_ciclo, cerrar_ciclo, estado_ciclo
  functions/gasto/index.ts     POST /gasto — endpoint del Atajo
```

## Requisitos

- Una cuenta de Supabase con un proyecto creado
- [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started)
- Un iPhone con la app Atajos

## Instalación

**1. Migraciones**

```bash
supabase db push
```

> Si `supabase link` falla con `"Your account does not have the necessary privileges"`,
> abre el SQL Editor del dashboard y pega `001_schema.sql` y después `002_ciclos.sql`.
> Dos ejecuciones y queda listo. También funciona
> `supabase db push --db-url "<connection string de Settings → Database>"`.

**2. Token del Atajo**

```bash
openssl rand -hex 24                      # genera el token
supabase secrets set SHORTCUT_TOKEN=<el token>
```

Guárdalo donde tengas tus claves: no se vuelve a mostrar.

**3. Desplegar el endpoint**

```bash
supabase functions deploy gasto
```

Queda en `https://<project-ref>.supabase.co/functions/v1/gasto`.

## Configuración inicial del ciclo

Con tus números, en el SQL Editor:

```sql
-- Fijos
insert into fijos (nombre, monto, dia_aprox) values
  ('Alquiler', 2320, 1);

-- Servicios (el estimado se recalcula solo con los últimos 3 pagos)
insert into servicios (nombre, empresa, codigo_usuario, monto_estimado, dia_aprox) values
  ('Luz',      'Luz del Sur', null, 150, 15),
  ('Internet', null,          null, 130, 10),
  ('Celular',  null,          null, 120, 20);

-- Abre el ciclo el día que cobras
select abrir_ciclo('2026-09-30', 'Octubre 2026');

-- El ingreso que dispara el ciclo
insert into ingresos (periodo_id, fuente, monto, fecha, confirmado, principal)
values (ciclo_actual(), 'TWNSTUDIOS', 2100, '2026-09-30', true, true),
       (ciclo_actual(), 'Oficina',    5000, '2026-09-30', true, false);

-- Ajusta la regla del ciclo
update config_ciclo
set pct_ahorro = 30, monto_esposa = 500
where periodo_id = ciclo_actual();
```

Para un mes de solo medición, sin alertas: `pct_ahorro = 0` y `dia_inicio_eval = 99`.

## El Atajo de iOS

Nombre: **Gasto** (el nombre es también el comando de Siri).

| # | Acción                  | Configuración                                        |
|---|-------------------------|------------------------------------------------------|
| 1 | Pedir entrada           | tipo Número, pregunta "¿Cuánto?"                     |
| 2 | Elegir entre un menú    | `Interbank`, `Efectivo`, `BCP` → cada rama un Texto en minúscula |
| 3 | Obtener contenido de URL| POST a tu endpoint                                    |
| 4 | Vibrar                  |                                                       |

En la acción 3:

- **Método**: `POST`
- **Encabezados**: `Authorization` → `Bearer <tu token>` (ojo con el espacio)
- **Cuerpo**: JSON con `monto` (el Número del paso 1) y `metodo` (el Texto del paso 2)
- **Desactiva "Mostrar al ejecutar"** — si no, iOS abre la app entera y el gesto se
  siente lento. Hazlo también en Vibrar.

Para abrirlo rápido: mantén presionada la pantalla de bloqueo → Personalizar → Pantalla
bloqueada → reemplaza el botón de la cámara por el Atajo. Es el acceso más corto que hay;
el Centro de Control sirve de respaldo.

El gesto completo debería durar menos de cinco segundos. Si pasa de ahí, recorta el input.

## Verificar

```sql
select fecha, monto, banco, tipo, origen
from movimientos where origen = 'shortcut'
order by fecha desc limit 5;

select * from estado_ciclo();
```

## API

```
POST /functions/v1/gasto
Authorization: Bearer <SHORTCUT_TOKEN>

{ "monto": 42.80, "metodo": "interbank", "comercio": "Tottus", "nota": "..." }
```

Solo `monto` es obligatorio; `metodo` cae a `interbank` por defecto. Responde con el id
del movimiento y el estado del ciclo (`disponible`, `permitido_dia`, `estado`).

## Estado

- [x] **Fase 1** — esquema, motor de ciclos, endpoint y Atajo
- [ ] **Fase 2** — Worker con los parsers de correo (BCP, Yape servicios, Yape P2P, Plin)
- [ ] **Fase 3** — resumen diario y frontend

La fase 2 arranca recién después de dos semanas usando el Atajo. La entrada manual es la
única pieza que depende de cambiar un hábito: si va a fallar, mejor que falle ahora y no
con todo el pipeline ya construido.
