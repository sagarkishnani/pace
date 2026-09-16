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
  functions/gasto/index.ts     POST /gasto — endpoint del Atajo de iOS
worker/
  src/texto.ts                 normalización de correo y extracción de campos
  src/parsers.ts               los cuatro parsers
  src/index.ts                 handler de Cloudflare Email Worker
  test/correos.ts              los cuatro correos reales, literales
```

No es un repo git. El README que se mencionó en el diseño nunca llegó al disco.

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

**Retirar de ahorros no es ingreso.** `ingresos.es_retiro = true` suma a la caja
disponible pero no entra al cálculo del ahorro — si no, el motor "ahorraría" el 30% de
plata que acabas de sacar del ahorro.

**`consumo_monedero` se excluye del gasto.** Ya se pagó al recargar; contarlo duplica.

**Los documentos nunca crean un movimiento.** `documentos` (boletas, recibos) se enlazan
a un movimiento existente o quedan en `pendiente` / `revisar`.

**Las categorías tienen un vocabulario canónico y vive en el endpoint.** La lista está
en `CATEGORIAS` dentro de `functions/gasto/index.ts`: `comida`, `restaurante`,
`transporte`, `salud`, `hogar`, `personal`, `otro`. No hay tabla catálogo ni check
constraint a propósito — el menú del Atajo está hardcodeado en iOS y no se sincroniza con
la base, así que una tabla daría fricción sin ganar nada, y un constraint haría frágiles
a los parsers de la fase 2. El endpoint es el único guardián. Los parsers de correo tienen
que emitir estas mismas categorías al resolver `comercios.categoria`, si no el resumen
sale partido en dos vocabularios.

Una categoría desconocida **no rechaza el movimiento**: entra con `categoria` nula y el
valor crudo queda en `raw.categoria_cruda`. Mismo criterio que `metodo`, que cae a
`interbank`. El Atajo corre parado en una caja; perder el gasto es peor que perder el
metadato.

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

## El Worker de correo

Cloudflare Email Worker. Parsea e inserta, nada más — todo lo demás lo hacen los triggers.

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

**Un 23505 cuenta como éxito.** Cloudflare reintenta ante un error y un duplicado no es un
fallo: si se lanzara, el reintento quedaría en bucle.

**Yape P2P trae los últimos dígitos del celular del beneficiario.** El nombre llega
truncado (`Antuanet Var*`) y solo se presta a colisiones; la llave de `destinatarios` es
`nombre #sufijo`. El nombre legible va aparte en `destinatario_nombre`, que es lo que
termina en el alias.

**Plin llega por Interbank pero no cierra el agujero de Interbank.** Ese correo solo cubre
transferencias Plin; el consumo con tarjeta Interbank sigue sin canal y sigue dependiendo
del Atajo.

### Correr los tests

```bash
cd worker && npm test
```

No necesita `npm install`: los tests solo tocan `texto.ts` y `parsers.ts`, y corren con el
soporte nativo de TypeScript de Node 22. Las fixtures son los cuatro correos reales, tal
cual llegan — su valor está en que son literales, así que no los edites al refactorizar.

## Captura de gastos por fuente

| Fuente            | Cómo entra                                  |
|-------------------|---------------------------------------------|
| BCP tarjeta       | correo — trae 4 dígitos, comercio, operación |
| Yape servicios    | correo — trae empresa y código de usuario    |
| Yape P2P, Plin    | correo — Plin trae código de operación       |
| Recibos comercio  | correo                                       |
| **Interbank**     | **manual, vía Atajo de iOS** — no hay canal de correo |
| Efectivo          | Atajo de iOS                                 |

Interbank es el único agujero y es el punto débil del sistema: todo lo que no capture el
Atajo hay que atraparlo en la reconciliación semanal. Por eso el match de servicios va por
`codigo_usuario`, no por monto.

## Fases

1. **Hecho** — Atajo de iOS + `/gasto`.
2. **Hecho** — motor de matching en la base y Worker con los cuatro parsers.
3. Resumen diario y frontend.

Pendiente antes de dar la fase 2 por cerrada: desplegar el Worker y confirmar contra
correos que lleguen de verdad. Los parsers están probados contra los cuatro formatos
reales, pero sobre el texto ya renderizado — no sobre el MIME crudo que entrega
Cloudflare.

Estado del ciclo actual: setiembre es mes de déficit deliberado (`pct_ahorro = 0`, alertas
apagadas, solo medición). Desde octubre el ingreso pasa a 7100 (2100 TWNSTUDIOS + 5000
oficina), alquiler 2320 fijo, 500 a la esposa, servicios ~400 estimados. Noviembre es el
primer ciclo con el sistema al 100% y con dos ciclos de datos reales detrás.

## El Atajo de iOS

Se llama `Gasto`. Acciones: Pedir Número ("¿Cuánto?") → Elegir entre un menú
(`interbank` / `efectivo` / `bcp`, en ese orden) → Elegir entre un menú (categoría) →
Obtener contenido de URL (POST) → Vibrar. **"Mostrar al ejecutar" desactivado** en la
acción de red, si no iOS abre la app entera y el gesto se siente lento.

El menú de categoría es el tercer toque y es el que más riesgo tiene de romper el hábito.
Si el gesto empieza a pasar de cinco segundos, la salida es recortar la lista o sacar el
paso y categorizar en la reconciliación semanal — no aguantarse la fricción. El monto es
lo único que no se puede posponer.

Acceso: botón de la pantalla de bloqueo (reemplaza la cámara) y Centro de Control como
respaldo. El objetivo es que el gesto completo dure menos de cinco segundos; si pasa de
ahí, hay que recortar el input, no aguantarse.

Auth: header `Authorization: Bearer <SHORTCUT_TOKEN>`, comparado contra el secret del
mismo nombre en Supabase. El token nunca va al repo.

## Comandos

```bash
supabase functions deploy gasto
supabase secrets set SHORTCUT_TOKEN=...
supabase db push

cd worker && npm test           # parsers contra los correos reales
cd worker && npx wrangler deploy
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
