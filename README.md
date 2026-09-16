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
  migrations/003_matching.sql  normalización, enlace de servicios, triggers
  migrations/004_comercios.sql catálogo de comercios
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

| # | Acción                  | Configuración                                                    |
|---|-------------------------|------------------------------------------------------------------|
| 1 | Pedir entrada           | tipo Número, pregunta "¿Cuánto?"                                 |
| 2 | Elegir entre un menú    | método: `Interbank`, `Efectivo`, `BCP`                           |
| 3 | Elegir entre un menú    | categoría: `Comida`, `Restaurante`, `Transporte`, `Salud`, `Hogar`, `Personal`, `Otro` |
| 4 | Obtener contenido de URL| POST a tu endpoint                                                |
| 5 | Vibrar                  |                                                                   |

En los pasos 2 y 3, dentro de cada rama del menú va una acción **Texto** con el valor en
minúscula (`interbank`, `comida`, …). Esos son los que entiende el endpoint. Pon primero
lo que más usas: en iOS la primera opción queda bajo el pulgar.

En la acción 4:

- **Método**: `POST`
- **Encabezados**: `Authorization` → `Bearer <tu token>` (ojo con el espacio)
- **Cuerpo**: JSON con tres campos
  - `monto` → el Número del paso 1
  - `metodo` → el Texto del paso 2
  - `categoria` → el Texto del paso 3
- **Desactiva "Mostrar al ejecutar"** — si no, iOS abre la app entera y el gesto se
  siente lento. Hazlo también en Vibrar.

Para abrirlo rápido: mantén presionada la pantalla de bloqueo → Personalizar → Pantalla
bloqueada → reemplaza el botón de la cámara por el Atajo. Es el acceso más corto que hay;
el Centro de Control sirve de respaldo.

### Sobre el tercer paso

Con la categoría el gesto pasa de dos toques a tres, y ese es el costo real del cambio.
El presupuesto sigue siendo cinco segundos de punta a punta. Cronometra una semana antes
de darlo por bueno.

Si te frena, hay dos salidas antes de resignarte:

- **Recortar la lista.** Siete opciones ya obligan a leer. Con cuatro o cinco eliges por
  posición, sin leer, que es lo que hace rápido a un menú.
- **Sacar el paso 3 y categorizar en la reconciliación semanal.** El endpoint acepta el
  gasto sin `categoria` sin problema: entra con categoría nula y la pones después, en
  frío y con el comercio a la vista. Registrar el monto es lo que no se puede posponer;
  la categoría sí.

Una categoría que el endpoint no reconozca **no bota el registro**: el gasto entra igual,
sin categoría, y el valor crudo queda guardado en `raw.categoria_cruda`.

## Verificar

```sql
select fecha, monto, banco, tipo, categoria, origen
from movimientos where origen = 'shortcut'
order by fecha desc limit 5;

select * from estado_ciclo();

-- Gasto variable del ciclo por categoría
select coalesce(categoria, 'sin categoría') as categoria,
       count(*), sum(monto)
from movimientos
where periodo_id = ciclo_actual()
  and fijo_id is null and servicio_id is null
  and tipo <> 'consumo_monedero'
group by 1 order by sum(monto) desc;
```

## API

```
POST /functions/v1/gasto
Authorization: Bearer <SHORTCUT_TOKEN>

{ "monto": 42.80, "metodo": "interbank", "categoria": "comida",
  "comercio": "Tottus", "nota": "..." }
```

| Campo       | Obligatorio | Por defecto                                  |
|-------------|-------------|----------------------------------------------|
| `monto`     | sí          | —                                            |
| `metodo`    | no          | `interbank`; uno desconocido también cae ahí |
| `categoria` | no          | nula; una desconocida cae a nula y se guarda en `raw.categoria_cruda` |
| `comercio`  | no          | nulo                                         |
| `moneda`    | no          | `PEN`                                        |
| `nota`      | no          | nula                                         |

Categorías válidas: `comida`, `restaurante`, `transporte`, `salud`, `hogar`, `personal`,
`otro`. Son solo de gasto variable — los fijos y los servicios no pasan por acá. Si
cambias la lista, cámbiala en `CATEGORIAS` dentro de `supabase/functions/gasto/index.ts`
y en el menú del Atajo; las dos tienen que decir lo mismo.

Responde con el id del movimiento, la categoría con la que quedó, y el estado del ciclo
(`disponible`, `permitido_dia`, `estado`).

## Consultas de la reconciliación semanal

```sql
select * from sin_resolver();        -- lo que quedó sin categoría o sin confirmar
select * from recibos_pendientes();  -- recibos vencidos que nunca llegaron
select enlazar_documentos();         -- amarra boletas sueltas a sus movimientos
```

## Estado

- [x] **Fase 1** — esquema, motor de ciclos, endpoint y Atajo
- [x] **Fase 2a** — motor de matching en la base (migraciones 003 y 004)
- [ ] **Fase 2b** — Cloudflare Email Worker con los parsers (BCP, Yape servicios, Yape P2P, Plin)
- [ ] **Fase 3** — resumen diario y frontend

La 2b necesita los cuerpos reales de los cuatro correos para escribir los regexes. El
motor de matching ya está listo y no depende de ellos: el Worker solo tiene que insertar
en `movimientos` con `codigo_usuario`, `empresa` y `destinatario` dentro de `raw`.
