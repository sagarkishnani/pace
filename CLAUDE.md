# pace

Control de gastos personal (Perú, PEN). Backend en Supabase: Postgres + Edge Functions.
No hay frontend todavía. El objetivo de fondo no es "gastar menos" sino saber cuánto
margen real queda para ahorrar hacia una meta (inicial de depto / carro).

## Estructura

```
supabase/
  migrations/001_schema.sql    tablas, índices, RLS
  migrations/002_ciclos.sql    abrir_ciclo, cerrar_ciclo, estado_ciclo
  migrations/003_matching.sql  normalización, enlace de servicios, triggers
  migrations/004_comercios.sql catálogo de comercios (datos, no lógica)
  migrations/005_worker.sql    ajustes que salieron de los correos reales
  migrations/006_panel.sql     débito/crédito, hoy_lima, panel(), alertas, ingresos
  functions/gasto/index.ts     POST /gasto    — Atajo "Gasto"
  functions/ingreso/index.ts   POST /ingreso  — Atajo "Ingreso"
  functions/resumen/index.ts   GET  /resumen  — lo que lee el panel
  functions/alerta/index.ts    POST /alerta   — lo que dispara el cron
  functions/correo/index.ts    POST /correo   — webhook del correo entrante
  functions/_shared/vocabulario.ts  métodos, categorías, clases de ingreso
  functions/_shared/notificar.ts    formato del webhook de alertas
  functions/_shared/http.ts         CORS, token, waitUntil
  functions/_shared/texto.ts   normalización y extracción de campos
  functions/_shared/parsers.ts los cuatro parsers
  functions/_shared/webhook.ts lectura del payload del proveedor
web/index.html                 el panel: un archivo, sin dependencias ni build
test/
  correos.ts                   los cuatro correos reales, literales
```

## Reglas de negocio que el código asume

Estas decisiones no se deducen leyendo el SQL. Respetarlas antes de cambiar nada.

**El ciclo va de cobro a cobro, no de mes calendario.** Se abre cuando se confirma el
ingreso principal (`ingresos.principal = true and confirmado`), no cuando el calendario
dice que toca. Si el sueldo llega tarde, el ciclo anterior simplemente se estira — que es
lo que pasa en la realidad. Solo puede haber un ciclo abierto (`ux_periodo_abierto`).

**La configuración se congela al abrir el ciclo.** `config_ciclo` es por periodo, no
global. Editarla a mitad de camino recalcula al momento y deja rastro (`editado_en`,
`nota_edicion`). `abrir_ciclo()` copia la config del ciclo anterior.

**Fijos y servicios salen del pool variable desde el día 1.** Es deliberado: si el
alquiler entrara como gasto normal, el día 1 la proyección se dispararía a rojo. La bolsa
es *solo* gasto variable. `fijos_pendientes` en `estado_ciclo()` es informativo.

**El crédito cuenta al pasar la tarjeta, no al pagar el estado de cuenta.** El motor mide
margen para ahorrar, y un consumo a crédito ya se comió ese margen aunque la plata siga en
la cuenta. Contarlo al pagar dejaría el ciclo en verde mientras la tarjeta se llena.
`estado_ciclo()` separa `gastado_credito` de `gastado_contado` para que se vea cuánto de
la cuenta sigue comprometido, pero los dos van dentro de `gastado`.

**`pago_tarjeta` se excluye del gasto.** Es el corolario de lo anterior: si el pago del
estado de cuenta contara, los mismos soles saldrían dos veces de la bolsa. Mismo criterio
que `consumo_monedero`. Se registra igual, para que la reconciliación cuadre contra el
extracto.

**El día lo decide Lima, no UTC.** `hoy_lima()`, no `current_date`. En un servidor UTC el
día cambia a las 7 de la noche de Lima: un gasto de la cena caía en el día siguiente y el
contador de días del ciclo se adelantaba toda la tarde — justo el número que más se mira.

**Retirar de ahorros no es ingreso.** `ingresos.es_retiro = true` suma a la caja
disponible pero no entra al cálculo del ahorro — si no, el motor "ahorraría" el 30% de
plata que acabas de sacar del ahorro.

**`consumo_monedero` se excluye del gasto.** Ya se pagó al recargar; contarlo duplica.

**Los documentos nunca crean un movimiento.** `documentos` (boletas, recibos) se enlazan
a un movimiento existente o quedan en `pendiente` / `revisar`.

**Las categorías tienen un vocabulario canónico y vive en `_shared/vocabulario.ts`.** La
lista está en `CATEGORIAS`: `comida`, `restaurante`, `transporte`, `salud`, `hogar`,
`personal`, `otro`. Siete, y así se quedan — se revisó agregar más y la respuesta fue que
el menú del Atajo es el cuello de botella, no el vocabulario. Vive en `_shared` y no
dentro del handler por lo mismo que `webhook.ts`: dentro del handler no se puede probar,
porque el handler importa Deno y supabase-js. No hay tabla catálogo ni check
constraint a propósito — el menú del Atajo está hardcodeado en iOS y no se sincroniza con
la base, así que una tabla daría fricción sin ganar nada, y un constraint haría frágiles
a los parsers de la fase 2. El endpoint es el único guardián. Los parsers de correo tienen
que emitir estas mismas categorías al resolver `comercios.categoria`, si no el resumen
sale partido en dos vocabularios.

Una categoría desconocida **no rechaza el movimiento**: entra con `categoria` nula y el
valor crudo queda en `raw.categoria_cruda`. Mismo criterio que `metodo`, que cae a
`interbank_credito` y deja `raw.metodo_crudo`. El Atajo corre parado en una caja; perder
el gasto es peor que perder el metadato. El monto es lo único que sí rechaza el registro:
es lo único que no se puede reconstruir después.

**El menú del Atajo y `METODOS` no son la misma lista.** El endpoint acepta más claves de
las que el menú muestra (`yape`, `plin`, `pago_bcp`, `recarga_monedero`…) porque cambiar
el menú es un trámite manual en el iPhone y mientras tanto lo viejo tiene que seguir
entrando. `bcp` e `interbank` sin sufijo —lo que mandaba el Atajo antes de separar débito
de crédito— siguen entrando como crédito.

**Deduplicación por referencia del banco, no por hash.** `unique (banco, ref_operacion)`
es la llave principal; `hash_origen` es solo respaldo para fuentes que no traen
referencia (Yape, el Atajo). Reprocesar un correo debe ser inocuo.

**El sobrante del ciclo se barre al ahorro** en `cerrar_ciclo()`.

**Antes de `dia_inicio_eval` el estado es siempre verde.** La proyección con 2 días de
datos es ruido.

## Matching (migración 003)

El enriquecimiento vive en la base, no en el Worker. El Worker solo parsea el correo e
inserta en `movimientos` con lo crudo en `raw`; el trigger `tg_enriquecer_movimiento`
resuelve servicio, comercio y categoría antes de guardar.

**Contrato de `raw`.** Estas tres claves son las que lee el trigger:

| Clave            | Quién la trae        | Para qué                                  |
|------------------|----------------------|-------------------------------------------|
| `codigo_usuario` | Yape servicios       | match exacto contra `servicios`           |
| `empresa`        | Yape servicios, BCP  | match de respaldo si no hay código        |
| `destinatario`   | Yape P2P, Plin       | categoría aprendida vía `destinatarios`   |

Todo lo demás del correo va igual a `raw` — es el respaldo cuando un parser resulte estar
mal y haya que reprocesar sin volver al correo.

**El trigger nunca pisa lo que ya decidiste.** Solo rellena campos nulos. Una categoría
que mandó el Atajo o que corregiste a mano sobrevive al catálogo de comercios.

**Gana el patrón más largo** en `buscar_comercio()`. Por eso `DIDI FOOD` y `DIDI` conviven
sin que el delivery termine contado como transporte. Si agregas un patrón que es prefijo
de otro, verifica ese caso.

**Un movimiento atado a un fijo o servicio pierde la categoría.** Es deliberado: las
categorías son solo de gasto variable y `estado_ciclo()` ya excluye esos movimientos de la
bolsa. Si además llevaran categoría, el resumen por categoría contaría plata que no está
en la bolsa.

**Ante la duda, no enlazar.** `buscar_servicio()` devuelve `ambiguo` cuando dos servicios
activos quedan a menos del 15% de distancia del monto, y el trigger deja el movimiento
suelto. Sale en `sin_resolver()` y lo arreglas en la reconciliación semanal. Un enlace
equivocado es más caro que uno faltante: el faltante se ve, el equivocado no.

**`recibos_pendientes()` es lo único que avisa por algo que no pasó** — un servicio cuyo
`vence_el` ya pasó y no tiene movimiento en el ciclo.

## El panel y las alertas (migración 006)

**`panel()` devuelve todo en un jsonb y una sola llamada.** El panel se abre desde el
celular con señal de calle; ocho viajes son medio segundo cada uno y un estado a medio
cargar. Además mantiene la regla de la casa: los números salen de `estado_ciclo()` y nadie
los recalcula en el cliente. Si el panel empezara a sumar por su cuenta habría dos
verdades, y la del celular sería la que se mira.

**El panel lee por `/resumen`, no por PostgREST.** RLS está activo sin políticas públicas:
la `anon key` no lee nada. La alternativa sería meter la `service_role key` en el
navegador, que es exactamente lo que no se hace nunca. `/resumen` usa `PANEL_TOKEN`, un
token propio —el navegador del celular está más expuesto que el Atajo y rotarlo no obliga
a reconfigurar el iPhone.

**El panel es de solo lectura.** Las correcciones siguen yendo por el SQL Editor en la
reconciliación semanal. Agregar escrituras significa otro endpoint y más superficie; la
decisión fue esperar a que la falta se sienta.

**`web/index.html` no tiene dependencias ni build.** Los gráficos son SVG escrito a mano.
Una librería de charts pesa más que todo el archivo y hay que mantenerla al día.

**`evaluar_alerta()` decide, el endpoint solo hace el POST.** Por lo mismo que los
números: una sola fuente. Avisa cuando el estado **sube**, cuando sigue en rojo y pasó un
día, y cuando sale de rojo. No avisa al bajar de ámbar a verde — eso es el sistema
funcionando, y una notificación que no pide nada enseña a ignorar las que sí.

**El aviso de escalada sale desde `/gasto`, no desde el cron.** El momento en que sirve es
cuando el gasto que acabas de registrar es el que cambió el estado: sigues parado en la
caja. Va con `EdgeRuntime.waitUntil` para no gastarle al gesto su presupuesto de cinco
segundos.

**El formato del webhook se deduce del dominio** (`ntfy.sh`, Telegram, Pushcut, Discord,
JSON genérico). Un solo secret en vez de dos evita el estado imposible de tener la URL de
un proveedor y el formato de otro.

**`alertas_activas` apaga las alertas sin tocar el motor.** Reemplaza el truco de
`dia_inicio_eval = 99`, que sigue funcionando igual.

## Ingresos (`registrar_ingreso`)

**`sueldo` rota el ciclo; `extra` y `retiro` no.** Cerrar el ciclo barre el sobrante al
ahorro y no se deshace con un toque, así que hay una guarda: un `sueldo` con el ciclo de
menos de 20 días **registra el ingreso pero no rota**, y devuelve el motivo en texto.
Cubre el caso normal de cobrar en dos partes (Oficina y TWNSTUDIOS el mismo día) y el de
un mal toque. `p_forzar` la salta.

**Perder el ingreso sería peor que no rotar.** Es el número del que cuelga todo lo demás:
un ingreso que no suma deja la bolsa en negativo y el ciclo en rojo sin que nada parezca
roto. Por eso el ingreso entra siempre, rote o no.

**El orden importa:** cerrar el ciclo viejo → abrir el nuevo → insertar el ingreso. Al
revés, `tg_asignar_ciclo_ingreso` lo mete en el ciclo que está por cerrarse e infla su
sobrante.

## La entrada de correo

> **No está enchufada.** Está construida y probada contra los cuatro correos reales, pero
> el dueño decidió quedarse en registro manual: un parser que lee mal un correo falla en
> silencio, y eso cuesta más que un gasto que nadie registró. Nada de acá se borró — se
> enciende el día que el Atajo pese demasiado. Todo lo de abajo sigue siendo cierto.

Un proveedor de correo entrante (Postmark, CloudMailin, Mailgun) recibe el correo del
banco y hace POST a `/correo` con el cuerpo ya parseado. La función lo convierte en
movimiento, nada más — todo lo demás lo hacen los triggers.

**No hay dominio propio.** Se evaluó Cloudflare Email Routing y se descartó: exige un
dominio con los MX apuntando a Cloudflare, y el único dominio disponible
(`twnstudios.com`) tiene el correo de trabajo en Google Workspace y el sitio en
CloudFront. No vale la pena poner eso en juego por este proyecto.

**El payload se lee en los tres formatos** (`TextBody`/`plain`/`body-plain` y sus
equivalentes HTML), y acepta JSON o formulario. Soportarlos todos cuesta diez líneas y
evita quedar casado con un proveedor.

**Se prefiere el texto plano sobre el HTML.** Es el que manda el proveedor ya limpio, y
ahorra el paso de HTML a texto, que es el más frágil de la cadena.

**Los parsers deciden por contenido, no por remitente.** Los bancos cambian de dominio de
envío más seguido que de plantilla. El remitente solo se usa como filtro de seguridad.

**Todo se compara sin tildes.** No es capricho: el propio correo del BCP advierte que las
tildes y las ñ pueden salir cambiadas según el cliente de correo. Buscar `"Código"` literal
es apostar a que el render salió bien.

**`banco` guarda el sistema de origen, no la cuenta.** `BCP`, `Yape`, `Plin`, `Interbank`,
`Efectivo`. Eso mantiene limpio el espacio de numeración del índice único
`(banco, ref_operacion)`: un Nº de operación de Yape y uno de tarjeta BCP pueden coincidir
sin ser el mismo gasto.

**Los cuatro correos traen número de operación**, así que la deduplicación siempre va por
referencia. El hash es red de seguridad, no el camino normal.

**Un 23505 cuenta como éxito, y los descartes responden 200.** El proveedor reintenta
ante cualquier error. Un duplicado, un remitente desconocido o un correo sin parser no se
arreglan reintentando, así que devolver error los dejaría en bucle.

**Yape P2P trae los últimos dígitos del celular del beneficiario.** El nombre llega
truncado (`Antuanet Var*`) y solo se presta a colisiones; la llave de `destinatarios` es
`nombre #sufijo`. El nombre legible va aparte en `destinatario_nombre`, que es lo que
termina en el alias.

**Plin llega por Interbank pero no cierra el agujero de Interbank.** Ese correo solo cubre
transferencias Plin; el consumo con tarjeta Interbank sigue sin canal y sigue dependiendo
del Atajo.

**`/correo` va con `verify_jwt = false`** (en `config.toml`): el proveedor no manda JWT de
Supabase. Se autentica con `CORREO_TOKEN`, por Bearer o por Basic con el token como
contraseña, que es como lo manda Postmark cuando pones credenciales en la URL.

### Correr los tests

```bash
npm test
```

No necesita `npm install` ni dependencias: corren con el soporte nativo de TypeScript de
Node 22 sobre los módulos de `_shared`. Las fixtures de correo son los cuatro correos
reales, tal cual llegan — su valor está en que son literales, así que no los edites al
refactorizar.

Lo que no se puede probar así es cualquier `index.ts`, porque importan Deno y
supabase-js. Ese es el criterio para decidir qué va a `_shared`: la lectura del payload
(`webhook.ts`), el vocabulario de métodos y categorías (`vocabulario.ts`) y el formato de
las notificaciones (`notificar.ts`) están afuera del handler precisamente para poder
probarlos.

El SQL no tiene suite. Se valida levantando un Postgres local, corriendo las seis
migraciones en orden y sembrando un ciclo de ejemplo — así se encontraron el desborde del
eje y el `current_date` en UTC.

## Captura de gastos por fuente

Todo entra por el **Atajo de iOS**. La entrada de correo está construida y probada contra
los cuatro correos reales, pero **no está enchufada** y la decisión de dejarla así es del
dueño: el reconocimiento por plantilla de banco falla en silencio, y un gasto que el
parser leyó mal cuesta más que uno que nadie registró. Nada de lo del correo se borró;
se enciende el día que el registro manual pese demasiado.

El menú del Atajo:

| Opción             | metodo              | Queda como          |
|--------------------|---------------------|---------------------|
| BCP crédito        | `bcp_credito`       | BCP · credito       |
| Interbank crédito  | `interbank_credito` | Interbank · credito |
| BCP débito         | `bcp_debito`        | BCP · debito        |
| Interbank débito   | `interbank_debito`  | Interbank · debito  |
| Efectivo           | `efectivo`          | Efectivo · efectivo |

**Yape y Plin no están en el menú a propósito.** Yape sale de la cuenta BCP y Plin de la
Interbank, así que registrarlos como el débito que son deja los números iguales y el menú
más corto. El endpoint los acepta igual: los parsers de correo emiten esos tipos y el
trigger aprende destinatarios solo para `yape` y `plin`.

Con todo en manual, el punto débil ya no es Interbank sino el hábito: lo que no capture el
Atajo hay que atraparlo en la reconciliación semanal.

## Fases

1. **Hecho** — Atajo de iOS + `/gasto`.
2. **Hecho, sin enchufar** — motor de matching en la base y los cuatro parsers tras
   `/correo`. Falta contratar el proveedor y apuntar el webhook, y por ahora no se va a
   hacer: se prefiere el registro manual (ver arriba).
3. **Hecho** — débito vs crédito, Atajo de ingresos, panel (`web/index.html`) y alertas
   por webhook.

Estado del ciclo actual: setiembre es mes de déficit deliberado (`pct_ahorro = 0`, alertas
apagadas, solo medición). Desde octubre el ingreso pasa a 7100 (2100 TWNSTUDIOS + 5000
oficina), alquiler 2320 fijo, 500 a la esposa, servicios ~400 estimados. Noviembre es el
primer ciclo con el sistema al 100% y con dos ciclos de datos reales detrás.

## Los Atajos de iOS

**`Gasto`.** Pedir Número ("¿Cuánto?") → menú de método (5 opciones) → menú de categoría
(7) → Obtener contenido de URL (POST a `/gasto`) → Vibrar. **"Mostrar al ejecutar"
desactivado** en la acción de red y en Vibrar: si no, iOS abre la app entera y el gesto se
siente lento.

El menú de categoría es el tercer toque y es el que más riesgo tiene de romper el hábito.
Si el gesto empieza a pasar de cinco segundos, la salida es recortar la lista o sacar el
paso y categorizar en la reconciliación semanal — no aguantarse la fricción. El monto es
lo único que no se puede posponer. **Cinco métodos, no siete**: es la razón por la que
Yape y Plin no están en el menú.

**`Ingreso`.** Pedir Número ("¿Cuánto entró?") → menú de clase (`sueldo` / `extra` /
`retiro`) → menú de fuente (`Oficina` / `TWNSTUDIOS` / `Otro`) → POST a `/ingreso` →
Notificación con el campo `resumen`.

Acá sí conviene **dejar "Mostrar al ejecutar" activado**, o mostrar el `resumen`: un
ingreso pasa dos veces al mes y vale confirmar si rotó el ciclo. El gasto es lo que tiene
que ser invisible; esto no.

Acceso: botón de la pantalla de bloqueo (reemplaza la cámara) y Centro de Control como
respaldo. El objetivo es que el gesto completo dure menos de cinco segundos; si pasa de
ahí, hay que recortar el input, no aguantarse.

Auth: header `Authorization: Bearer <SHORTCUT_TOKEN>` en los dos, comparado contra el
secret del mismo nombre en Supabase con comparación de largo constante. El token nunca va
al repo.

## Comandos

```bash
supabase db push
npm test                        # vocabulario, notificaciones y parsers

supabase secrets set SHORTCUT_TOKEN=...   # los dos Atajos
supabase secrets set PANEL_TOKEN=...      # el panel y el cron de alertas
supabase secrets set ALERTA_WEBHOOK_URL=https://ntfy.sh/pace-...
supabase secrets set CORREO_TOKEN=...     # solo si se enchufa el correo

supabase functions deploy gasto
supabase functions deploy ingreso
supabase functions deploy resumen
supabase functions deploy alerta
```

Las cuatro van con `verify_jwt = false` en `config.toml`: ninguna habla con un cliente de
Supabase, así que ninguna trae un JWT de Supabase en el `Authorization`. Con
`verify_jwt = true` el gateway las rechaza con 401 antes de que corran, y el error no dice
por qué.

Probar un mensaje de alerta sin gastarse una notificación:

```bash
curl -H "Authorization: Bearer $PANEL_TOKEN" \
  "https://<ref>.supabase.co/functions/v1/alerta?modo=diario&dry=1"
```

**`supabase link` falla** en este proyecto con `"Your account does not have the necessary
privileges"` (ref `csocvoxgqrfoevdzwglh`). Alternativas mientras no se resuelva: pegar las
migraciones en el SQL Editor del dashboard, o `supabase db push --db-url <DSN directo>`.
`functions deploy` sí necesita el link resuelto.

Verificar que un gasto llegó:

```sql
select fecha, monto, banco, tipo, origen
from movimientos where origen = 'shortcut'
order by fecha desc limit 5;
```

## Convenciones

- Todo en español: nombres de tablas, columnas, funciones y comentarios.
- Sin ORM. SQL directo y funciones de Postgres; `estado_ciclo()` es la única fuente de los
  números — no recalcular nada de eso en TypeScript.
- RLS habilitado en todas las tablas y **sin políticas públicas**: la `anon key` no lee
  nada. Todo acceso pasa por `service_role` (Edge Functions y el Worker).
- Los movimientos entran con `confirmado = false`; se confirman en la reconciliación
  semanal.
