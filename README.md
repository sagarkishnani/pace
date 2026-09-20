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

**El crédito cuenta el día que pasas la tarjeta, no el día que pagas el estado de
cuenta.** La pregunta del proyecto es cuánto margen queda para ahorrar, y un consumo a
crédito ya se comió ese margen aunque la plata siga en la cuenta. Contarlo recién al
pagar dejaría el ciclo en verde mientras la tarjeta se llena. El pago del estado de
cuenta se registra como `pago_tarjeta` y **no** vuelve a gastar: si contara, los mismos
soles saldrían dos veces de la bolsa. El panel muestra los dos números por separado —
cuánto ya salió de la cuenta y cuánto llega después como recibo.

Cada gasto entra por una de dos vías:

- **Atajo de iOS** (manual) — la vía principal. Un gasto son tres toques y el método dice
  banco y si fue débito o crédito.
- **Correo** (automático) — BCP tarjeta, Yape servicios, Yape P2P, Plin. Está construido
  y probado contra los correos reales, pero **no está en uso**: los parsers dependen de
  plantillas de banco que cambian, y un parser que falla en silencio es peor que no
  tenerlo. Queda listo para cuando el registro manual empiece a pesar.

El estado del ciclo se calcula en Postgres (`estado_ciclo()`) y devuelve verde, ámbar o
rojo según la proyección de gasto contra la bolsa.

## Estructura

```
supabase/
  migrations/001_schema.sql    tablas, índices, RLS
  migrations/002_ciclos.sql    abrir_ciclo, cerrar_ciclo, estado_ciclo
  migrations/003_matching.sql  normalización, enlace de servicios, triggers
  migrations/004_comercios.sql catálogo de comercios
  migrations/005_worker.sql    ajustes de los correos reales
  migrations/006_panel.sql     débito/crédito, panel(), alertas, ingresos
  functions/gasto/index.ts     POST /gasto    — Atajo "Gasto"
  functions/ingreso/index.ts   POST /ingreso  — Atajo "Ingreso"
  functions/resumen/index.ts   GET  /resumen  — lo que lee el panel
  functions/alerta/index.ts    POST /alerta   — lo que dispara el cron
  functions/correo/index.ts    POST /correo   — webhook del correo entrante
  functions/_shared/           vocabulario, parsers, notificaciones, HTTP
web/index.html                 el panel: un archivo, sin dependencias
test/                          los cuatro correos reales como fixtures
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

**3. Desplegar los endpoints**

```bash
supabase functions deploy gasto
supabase functions deploy ingreso
```

Quedan en `https://<project-ref>.supabase.co/functions/v1/<nombre>`. El panel
(`resumen`) y las alertas (`alerta`) tienen su propia sección más abajo.

> Los cuatro van con `verify_jwt = false` en `config.toml`: ninguno habla con un cliente
> de Supabase, así que ninguno trae un JWT de Supabase en el `Authorization` — el Atajo
> manda `SHORTCUT_TOKEN` y el panel `PANEL_TOKEN`. Con `verify_jwt = true` el gateway los
> rechaza con 401 antes de que la función llegue a correr, y el error no dice por qué.
> Cada función valida su token en el primer bloque del handler.

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

## Los Atajos de iOS

Dos Atajos: **Gasto** e **Ingreso**. El nombre es también el comando de Siri.

### Atajo "Gasto"

| # | Acción                  | Configuración                                                    |
|---|-------------------------|------------------------------------------------------------------|
| 1 | Pedir entrada           | tipo Número, pregunta "¿Cuánto?"                                 |
| 2 | Elegir entre un menú    | método — cinco opciones, abajo                                   |
| 3 | Elegir entre un menú    | categoría — siete opciones, abajo                                |
| 4 | Obtener contenido de URL| POST a `/gasto`                                                   |
| 5 | Vibrar                  |                                                                   |

**Menú de método** (paso 2). Dentro de cada rama va una acción **Texto** con el valor de
la derecha; ese es el que entiende el endpoint. Pon primero lo que más usas: en iOS la
primera opción queda bajo el pulgar.

| Opción del menú    | Texto               | Queda como           |
|--------------------|---------------------|----------------------|
| BCP crédito        | `bcp_credito`       | BCP · crédito        |
| Interbank crédito  | `interbank_credito` | Interbank · crédito  |
| BCP débito         | `bcp_debito`        | BCP · débito         |
| Interbank débito   | `interbank_debito`  | Interbank · débito   |
| Efectivo           | `efectivo`          | Efectivo             |

Yape y Plin no están en el menú a propósito: Yape sale de la cuenta BCP y Plin de la
Interbank, así que registrarlos como el débito que son deja los números iguales y el menú
más corto. Si algún día los quieres separados, el endpoint ya acepta `yape` y `plin` sin
tocar nada.

Lo que mandaba el Atajo viejo —`bcp` e `interbank`, sin sufijo— sigue entrando, como
crédito. No hace falta migrar nada de golpe.

**Menú de categoría** (paso 3). Estas siete y nada más:

| Opción del menú | Texto         | Qué cae ahí                        |
|-----------------|---------------|------------------------------------|
| Comida          | `comida`      | mercado, bodega, supermercado      |
| Restaurante     | `restaurante` | salir a comer, delivery            |
| Transporte      | `transporte`  | taxi, combustible, pasajes, peaje  |
| Salud           | `salud`       | farmacia, consultas, laboratorio   |
| Hogar           | `hogar`       | cosas para la casa                 |
| Personal        | `personal`    | ropa, cortes, gym                  |
| Otro            | `otro`        | lo que no encaja                   |

Son solo de **gasto variable**: los fijos y los servicios no pasan por acá. Si quieres
cambiar la lista hay que cambiarla en tres sitios y los tres tienen que decir lo mismo:
`CATEGORIAS` en `supabase/functions/_shared/vocabulario.ts`, la columna `categoria` de
`comercios` (migración 004) y el menú del Atajo.

En la acción 4:

- **Método**: `POST`
- **Encabezados**: `Authorization` → `Bearer <SHORTCUT_TOKEN>` (ojo con el espacio)
- **Cuerpo**: JSON con tres campos
  - `monto` → el Número del paso 1
  - `metodo` → el Texto del paso 2
  - `categoria` → el Texto del paso 3
- **Desactiva "Mostrar al ejecutar"** — si no, iOS abre la app entera y el gesto se
  siente lento. Hazlo también en Vibrar.

Para abrirlo rápido: mantén presionada la pantalla de bloqueo → Personalizar → Pantalla
bloqueada → reemplaza el botón de la cámara por el Atajo. Es el acceso más corto que hay;
el Centro de Control sirve de respaldo.

#### Registrar el pago de la tarjeta

No va en el menú porque no es un gesto diario, pero el endpoint acepta `pago_bcp` y
`pago_interbank`. Entran como `tipo = 'pago_tarjeta'`, que **no** cuenta como gasto: el
consumo ya contó el día que pasaste la tarjeta. Sirve para que la reconciliación cuadre
contra el extracto del banco. También está en SQL:

```sql
insert into movimientos (fecha, monto, banco, tipo, origen, confirmado)
values (now(), 1280.00, 'BCP', 'pago_tarjeta', 'manual', true);
```

#### Sobre el tercer paso

El gesto son tres toques y el presupuesto sigue siendo cinco segundos de punta a punta.
Cronometra una semana antes de darlo por bueno.

Si te frena, hay dos salidas antes de resignarte:

- **Recortar la lista.** Siete opciones ya obligan a leer. Con cuatro o cinco eliges por
  posición, sin leer, que es lo que hace rápido a un menú.
- **Sacar el paso 3 y categorizar en la reconciliación semanal.** El endpoint acepta el
  gasto sin `categoria` sin problema: entra con categoría nula y la pones después, en
  frío y con el comercio a la vista. Registrar el monto es lo que no se puede posponer;
  la categoría sí.

Una categoría o un método que el endpoint no reconozca **no botan el registro**: el gasto
entra igual y el valor crudo queda en `raw.categoria_cruda` / `raw.metodo_crudo`. Estás
parado en una caja cuando esto corre; perder el gasto es peor que perder el metadato.

### Atajo "Ingreso"

| # | Acción                  | Configuración                                          |
|---|-------------------------|--------------------------------------------------------|
| 1 | Pedir entrada           | tipo Número, pregunta "¿Cuánto entró?"                 |
| 2 | Elegir entre un menú    | clase — tres opciones                                  |
| 3 | Elegir entre un menú    | fuente — las tuyas                                     |
| 4 | Obtener contenido de URL| POST a `/ingreso`                                       |
| 5 | Mostrar notificación    | con `resumen` de la respuesta                          |

**Menú de clase** (paso 2):

| Opción del menú     | Texto    | Qué hace                                             |
|---------------------|----------|------------------------------------------------------|
| Sueldo — abre ciclo | `sueldo` | Cierra el ciclo anterior y abre uno nuevo desde hoy  |
| Otro ingreso        | `extra`  | Suma al ciclo en curso                               |
| Saqué de ahorros    | `retiro` | Suma a la caja pero **no** al ahorro                 |

**Menú de fuente** (paso 3): `Oficina`, `TWNSTUDIOS`, `Otro` — los textos van tal cual,
son solo etiquetas.

Acá sí conviene **dejar "Mostrar al ejecutar" activado** en la acción de red, o poner una
Notificación con el campo `resumen` de la respuesta: un ingreso pasa dos veces al mes y
vale la pena confirmar que rotó el ciclo. El gasto es lo que tiene que ser invisible, no
esto.

#### Qué pasa con `sueldo`

El ciclo va de cobro a cobro, así que el sueldo es el que lo mueve. `sueldo` cierra el
ciclo abierto —barriendo el sobrante al ahorro— y abre el siguiente empezando hoy. Si el
sueldo llega tarde, el ciclo anterior simplemente se estira, que es lo que pasa en la
realidad.

Cerrar un ciclo barre plata al ahorro y no se deshace con un toque, así que hay una
**guarda de 20 días**: un `sueldo` con el ciclo recién empezado registra el ingreso pero
**no** rota, y la respuesta dice por qué. Eso cubre el caso normal de cobrar en dos
partes —registras Oficina como `sueldo`, rota; registras TWNSTUDIOS como `sueldo` cinco
minutos después y no vuelve a rotar, solo suma. Para forzarlo, manda `forzar: true` en
el cuerpo (o usa un cuarto Atajo aparte para eso).

## El panel

`web/index.html` — un archivo, sin dependencias ni build. Lee de `GET /resumen` con un
token y no calcula nada: cada número que se ve salió de `estado_ciclo()` en Postgres.

Muestra el permitido de hoy, el medidor de la bolsa contra dónde tocaría ir, la curva de
gasto acumulado contra el plan y contra dónde llegas al ritmo actual, el reparto por
categoría, cuánto llega después como estado de cuenta, fijos y servicios pendientes, los
movimientos del ciclo y el sobrante barrido al ahorro por cada ciclo cerrado.

Es de **solo lectura**. Las correcciones —categorías, confirmaciones, enlaces— siguen
yendo por el SQL Editor en la reconciliación semanal.

**Desplegar:**

```bash
openssl rand -hex 24                        # token del panel, distinto al del Atajo
supabase secrets set PANEL_TOKEN=<el token>
supabase functions deploy resumen
```

Un token propio del panel porque vive en el navegador del celular, que es un sitio más
expuesto que el Atajo: rotarlo no obliga a reconfigurar nada en el iPhone. Si no lo pones,
`/resumen` cae a `SHORTCUT_TOKEN`.

**Abrirlo.** El archivo pide la URL del proyecto y el token la primera vez, y los guarda
en el `localStorage` de ese navegador. Tres formas de servirlo, de menos a más cómoda:

1. Abrir `web/index.html` con doble clic. Funciona para mirar desde la laptop.
2. `npx serve web` y abrirlo desde el celular en la misma red.
3. Subir la carpeta `web/` a Cloudflare Pages o Netlify (arrastrar y soltar, sin DNS ni
   dominio propio). Te dan una URL `.pages.dev`; ábrela en Safari y **Compartir → Añadir
   a inicio** para que quede como app con su propio icono.

`/resumen` responde con CORS abierto, que es seguro acá porque la llave es el token del
header: no hay cookie de sesión que un origen ajeno pueda aprovechar.

## Alertas

Avisan por webhook — no hay app propia ni la va a haber. Un solo secret y el formato del
payload se deduce del dominio: **ntfy.sh**, **Telegram**, **Pushcut**, **Discord**, o
JSON genérico para cualquier otro.

```bash
supabase secrets set ALERTA_WEBHOOK_URL=https://ntfy.sh/pace-<algo-que-nadie-adivine>
supabase functions deploy alerta
supabase functions deploy gasto        # para que avise al momento de gastar
```

Con ntfy: instalas la app, te suscribes a ese topic y listo, sin cuenta. El topic es la
única llave, así que ponle algo largo.

Con Telegram: creas un bot con @BotFather y usas
`https://api.telegram.org/bot<TOKEN>/sendMessage?chat_id=<TU_CHAT_ID>`. El `chat_id` sale
de la URL y pasa al cuerpo solo.

**Cuándo avisa.** La decisión está en `evaluar_alerta()`, no en el endpoint:

- El estado **sube** — verde → ámbar → rojo. Esto se dispara desde `/gasto`, en el momento
  en que el gasto que acabas de registrar es el que cambió el estado: sigues parado en la
  caja y todavía puedes hacer algo.
- Sigue en **rojo** y pasó un día del último aviso.
- **Sale** de rojo.
- El **resumen diario**, si pones el cron de abajo.

No avisa al bajar de ámbar a verde: eso es el sistema funcionando, y una notificación que
no pide nada enseña a ignorar las que sí.

**El resumen de la mañana.** En el SQL Editor (`pg_cron` + `pg_net` vienen con Supabase):

```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'pace-resumen-diario',
  '0 13 * * *',                      -- 13:00 UTC = 8:00 a. m. en Lima
  $$
  select net.http_post(
    url     := 'https://<project-ref>.supabase.co/functions/v1/alerta?modo=diario',
    headers := '{"Authorization": "Bearer <PANEL_TOKEN>",
                 "Content-Type": "application/json"}'::jsonb
  );
  $$
);
```

El token queda guardado en texto dentro de `cron.job`. Para un proyecto de una sola
persona con RLS cerrado da igual; si te incomoda, Supabase Vault lo guarda cifrado.

**Ver cómo queda un mensaje sin gastarse una notificación:**

```bash
curl -H "Authorization: Bearer $PANEL_TOKEN" \
  "https://<project-ref>.supabase.co/functions/v1/alerta?modo=diario&dry=1"
```

**Apagar las alertas** para un ciclo de solo medición:

```sql
update config_ciclo set alertas_activas = false where periodo_id = ciclo_actual();
```

Es más claro que el truco de `dia_inicio_eval = 99`, que sigue funcionando igual.

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
  and tipo not in ('consumo_monedero', 'pago_tarjeta')
group by 1 order by sum(monto) desc;
```

## API

### `POST /gasto` — Atajo "Gasto"

```
Authorization: Bearer <SHORTCUT_TOKEN>

{ "monto": 42.80, "metodo": "bcp_credito", "categoria": "comida",
  "comercio": "Tottus", "nota": "..." }
```

| Campo       | Obligatorio | Por defecto                                                  |
|-------------|-------------|--------------------------------------------------------------|
| `monto`     | sí          | — (es lo único que rechaza el registro)                      |
| `metodo`    | no          | `interbank_credito`; uno desconocido cae ahí y queda crudo en `raw.metodo_crudo` |
| `categoria` | no          | nula; una desconocida cae a nula y queda en `raw.categoria_cruda` |
| `comercio`  | no          | nulo — el trigger lo normaliza y de ahí saca la categoría    |
| `moneda`    | no          | `PEN`                                                        |
| `nota`      | no          | nula                                                         |

Métodos: `bcp_credito`, `bcp_debito`, `interbank_credito`, `interbank_debito`,
`efectivo`, `yape`, `plin`, `pago_bcp`, `pago_interbank`, `recarga_monedero`,
`consumo_monedero`. Alias: `bcp` e `interbank` (el Atajo viejo) entran como crédito.

Categorías: `comida`, `restaurante`, `transporte`, `salud`, `hogar`, `personal`, `otro`.

Responde con el id del movimiento, cómo quedó clasificado, el estado del ciclo
(`disponible`, `permitido_dia`, `estado`) y un `resumen` listo para mostrar.

### `POST /ingreso` — Atajo "Ingreso"

```
Authorization: Bearer <SHORTCUT_TOKEN>

{ "monto": 5000, "fuente": "Oficina", "clase": "sueldo" }
```

| Campo    | Obligatorio | Por defecto                                          |
|----------|-------------|------------------------------------------------------|
| `monto`  | sí          | —                                                    |
| `clase`  | no          | `extra`; una desconocida cae ahí                     |
| `fuente` | no          | `Sueldo` o `Otro` según la clase                     |
| `nota`   | no          | nula                                                 |
| `forzar` | no          | `false` — salta la guarda de 20 días de `sueldo`     |

Responde con `rotado` (si abrió un ciclo nuevo), `sobrante` (lo que se barrió al ahorro),
`motivo` en texto y el estado del ciclo resultante.

### `GET /resumen` — el panel

```
Authorization: Bearer <PANEL_TOKEN>      (o ?token=…)
```

Devuelve el jsonb de `panel()` tal cual: `estado`, `config`, `por_categoria`,
`por_metodo`, `por_dia`, `movimientos`, `ingresos`, `fijos`, `servicios`,
`sin_resolver`, `recibos_pendientes`, `historial`. Con `?periodo=<uuid>` lee un ciclo
cerrado. Responde con CORS abierto.

Existe en vez de pegarle a PostgREST desde el navegador porque RLS está activo sin
políticas públicas: la `anon key` no lee nada, y la `service_role` key no se pone en un
navegador jamás.

### `POST /alerta` — el cron

```
Authorization: Bearer <PANEL_TOKEN>
?modo=diario|cambio   &dry=1
```

Evalúa con `evaluar_alerta()` y manda el aviso a `ALERTA_WEBHOOK_URL` si toca. Con
`dry=1` devuelve el mensaje sin mandarlo.

## La entrada de correo

Un proveedor de correo entrante te da una dirección hospedada, recibe la notificación del
banco y hace POST a `/correo` con el cuerpo ya parseado. La función lo convierte en
movimiento; el enriquecimiento —enlazar el servicio, normalizar el comercio, poner la
categoría— lo hace la base sola.

No hace falta dominio propio ni tocar DNS.

Cubre cuatro formatos:

| Correo          | Remitente                                 | Llave que aporta       |
|-----------------|-------------------------------------------|------------------------|
| BCP tarjeta     | `notificaciones@notificacionesbcp.com.pe` | 4 dígitos y comercio   |
| Yape servicios  | `notificaciones@yape.pe`                  | código de usuario      |
| Yape P2P        | `notificaciones@yape.pe`                  | beneficiario + celular |
| Plin            | `servicioalcliente@netinterbank.com.pe`   | código de operación    |

**Probar los parsers** (sin dependencias, no necesita `npm install`):

```bash
npm test
```

**Desplegar:**

```bash
openssl rand -hex 24                        # token del webhook
supabase secrets set CORREO_TOKEN=<el token>
supabase functions deploy correo
```

Queda en `https://<project-ref>.supabase.co/functions/v1/correo`.

**Conectar el proveedor.** En Postmark, CloudMailin o Mailgun: creas un stream de correo
entrante, te dan una dirección, y apuntas su webhook a esa URL con el token. Postmark
acepta credenciales en la URL del webhook y las manda como Basic, que la función entiende:

```
https://pace:<el token>@<project-ref>.supabase.co/functions/v1/correo
```

Si tu proveedor no soporta Basic, manda el token como `Authorization: Bearer <el token>`.

**Reenviar desde Gmail.** Un filtro por remitente hacia la dirección del proveedor:

```
from:(notificaciones@yape.pe OR notificaciones@notificacionesbcp.com.pe OR servicioalcliente@netinterbank.com.pe)
```

Gmail pide verificar la dirección de reenvío con un código antes de dejarte usarla. Ese
código llega a la dirección del proveedor, así que lo lees en su panel de correos
recibidos — todos muestran el contenido del último mensaje.

**El filtro de remitente.** La función solo acepta correos de los tres remitentes de los
bancos. Si tu reenvío reescribe el `From:`, agrega tu dirección:

```bash
supabase secrets set REMITENTES=tu@gmail.com
```

Existe porque cualquiera que sepa la dirección puede escribirle haciéndose pasar por el
banco. El daño máximo es un movimiento inventado —que además aparece en `sin_resolver()`—
pero cerrar la puerta es gratis.

**Ver qué está llegando:**

```bash
supabase functions logs correo
```

## Consultas de la reconciliación semanal

```sql
select * from sin_resolver();        -- lo que quedó sin categoría o sin confirmar
select * from recibos_pendientes();  -- recibos vencidos que nunca llegaron
select enlazar_documentos();         -- amarra boletas sueltas a sus movimientos
```

## Estado

- [x] **Fase 1** — esquema, motor de ciclos, endpoint y Atajo
- [x] **Fase 2** — matching en la base y los cuatro parsers tras `/correo`
- [x] **Fase 3** — débito/crédito, Atajo de ingresos, panel y alertas

La entrada de correo está terminada y probada contra los cuatro correos reales, pero
**no está enchufada**: falta contratar el proveedor y apuntar el webhook. La decisión de
seguir en manual es deliberada — el reconocimiento por plantilla de banco falla en
silencio, y un gasto que el parser leyó mal es más caro que uno que no registró nadie.
Todo lo del correo queda en pie y se enciende el día que el registro manual pese
demasiado.

Con el sistema en manual, lo que hay que sostener es el hábito: el Atajo tiene que
seguir cabiendo en cinco segundos. Lo que se escape se atrapa en la reconciliación
semanal.
