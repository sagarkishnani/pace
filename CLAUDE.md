# pace

Control de gastos personal (Perú, PEN). Backend en Supabase: Postgres + Edge Functions.
No hay frontend todavía. El objetivo de fondo no es "gastar menos" sino saber cuánto
margen real queda para ahorrar hacia una meta (inicial de depto / carro).

## Estructura

```
supabase/
  migrations/001_schema.sql    tablas, índices, RLS
  migrations/002_ciclos.sql    funciones: abrir_ciclo, cerrar_ciclo, estado_ciclo
  functions/gasto/index.ts     POST /gasto — endpoint del Atajo de iOS
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

1. **Actual** — Atajo de iOS + `/gasto`. Se usa dos semanas antes de construir nada más.
   El orden es a propósito: la entrada manual es la única pieza que depende de cambiar un
   hábito, y si va a fallar conviene que falle ahora y no con el pipeline ya construido.
2. Worker con los cuatro parsers de correo (BCP, Yape servicios, Yape P2P, Plin).
3. Frontend / resumen diario.

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
