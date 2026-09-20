// ============================================================
// POST /gasto — endpoint del Atajo de iOS
//
// Body mínimo:   { "monto": 42.80 }
// Body completo: { "monto": 42.80, "metodo": "bcp_credito",
//                  "categoria": "comida", "comercio": "Tottus",
//                  "nota": "..." }
//
// Header: Authorization: Bearer <SHORTCUT_TOKEN>
//
// El vocabulario (métodos y categorías) vive en
// _shared/vocabulario.ts, que sí se puede probar. Acá solo queda
// el viaje a la base y el aviso.
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { leerMonto, resolverCategoria, resolverMetodo } from "../_shared/vocabulario.ts";
import { enSegundoPlano, json, tokenDe, tokenValido } from "../_shared/http.ts";
import { enviarAviso } from "../_shared/notificar.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Solo POST" }, 405);

  if (!tokenValido(tokenDe(req), Deno.env.get("SHORTCUT_TOKEN"))) {
    return json({ error: "No autorizado" }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "JSON inválido" }, 400);
  }

  // El monto es lo único que no se puede reconstruir después:
  // es lo único que sí rechaza el registro.
  const monto = leerMonto(body.monto);
  if (monto === null) return json({ error: "Falta un monto válido" }, 400);

  const { clave, metodo, cruda: metodoCrudo } = resolverMetodo(body.metodo);
  const { categoria, cruda: categoriaCruda } = resolverCategoria(body.categoria);

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // El periodo lo pone el trigger tg_enriquecer_movimiento. Si no
  // hay ciclo abierto queda nulo y abrir_ciclo() lo reencola.
  const { data: mov, error } = await db
    .from("movimientos")
    .insert({
      fecha: new Date().toISOString(),
      monto,
      moneda: String(body.moneda ?? "PEN"),
      comercio: body.comercio ?? null,
      categoria,
      banco: metodo.banco,
      tipo: metodo.tipo,
      origen: "shortcut",
      confirmado: false, // se confirma en la reconciliación semanal
      raw: {
        metodo: clave,
        nota: body.nota ?? null,
        metodo_crudo: metodoCrudo,
        categoria_cruda: categoriaCruda,
        recibido: new Date().toISOString(),
      },
    })
    .select("id")
    .single();

  if (error) {
    console.error("insert falló:", error);
    return json({ error: "No se pudo registrar" }, 500);
  }

  // El gasto que acaba de entrar puede ser justo el que cambia el
  // estado del ciclo, y ese es el momento en que el aviso sirve:
  // estás todavía parado en la caja.
  //
  // Las dos llamadas van juntas: son independientes y el gesto
  // tiene un presupuesto de cinco segundos.
  const [{ data: alerta }, { data: estado }] = await Promise.all([
    db.rpc("evaluar_alerta", { p_modo: "cambio" }),
    db.rpc("estado_ciclo"),
  ]);

  const a = Array.isArray(alerta) ? alerta[0] : alerta;
  const e = Array.isArray(estado) ? estado[0] : estado;

  if (a?.notificar) {
    enSegundoPlano(
      enviarAviso(Deno.env.get("ALERTA_WEBHOOK_URL"), {
        titulo: a.titulo,
        cuerpo: a.cuerpo,
        estado: a.estado,
      }),
    );
  }

  return json({
    ok: true,
    id: mov.id,
    monto,
    metodo: clave,
    banco: metodo.banco,
    tipo: metodo.tipo,
    categoria,
    disponible: e?.disponible ?? null,
    permitido_dia: e?.permitido_dia ?? null,
    estado: e?.estado ?? null,
    // Lo que el Atajo puede leer en voz alta o mostrar en la
    // notificación de iOS sin tener que armar el texto allá
    resumen: e
      ? `Queda S/ ${e.disponible} · hoy S/ ${e.permitido_dia}`
      : "Sin ciclo abierto",
  });
});
