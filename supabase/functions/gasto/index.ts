// ============================================================
// POST /gasto — endpoint del Atajo de iOS
//
// Body mínimo:  { "monto": 42.80 }
// Body completo: { "monto": 42.80, "metodo": "interbank",
//                  "comercio": "Tottus", "nota": "..." }
//
// Header: Authorization: Bearer <SHORTCUT_TOKEN>
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const METODOS: Record<string, { banco: string; tipo: string }> = {
  interbank: { banco: "Interbank", tipo: "credito" },
  bcp:       { banco: "BCP",       tipo: "credito" },
  efectivo:  { banco: "Efectivo",  tipo: "efectivo" },
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "Solo POST" }, 405);
  }

  const token = req.headers.get("Authorization")?.replace("Bearer ", "");
  if (!token || token !== Deno.env.get("SHORTCUT_TOKEN")) {
    return json({ error: "No autorizado" }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "JSON inválido" }, 400);
  }

  const monto = Number(body.monto);
  if (!Number.isFinite(monto) || monto <= 0) {
    return json({ error: "Falta un monto válido" }, 400);
  }

  const clave = String(body.metodo ?? "interbank").toLowerCase();
  const metodo = METODOS[clave] ?? METODOS.interbank;

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // El ciclo abierto; si no hay, el movimiento queda suelto
  // y abrir_ciclo() lo reencola después.
  const { data: periodoId } = await db.rpc("ciclo_actual");

  const { data: mov, error } = await db
    .from("movimientos")
    .insert({
      periodo_id: periodoId ?? null,
      fecha: new Date().toISOString(),
      monto,
      moneda: String(body.moneda ?? "PEN"),
      comercio: body.comercio ?? null,
      banco: metodo.banco,
      tipo: metodo.tipo,
      origen: "shortcut",
      confirmado: false,        // se confirma en la reconciliación semanal
      raw: { nota: body.nota ?? null, recibido: new Date().toISOString() },
    })
    .select("id")
    .single();

  if (error) {
    console.error("insert falló:", error);
    return json({ error: "No se pudo registrar" }, 500);
  }

  // Devuelve el estado para que el Atajo pueda mostrarlo si quieres
  const { data: estado } = await db.rpc("estado_ciclo", {
    p_periodo: periodoId ?? null,
  });

  const e = Array.isArray(estado) ? estado[0] : estado;

  return json({
    ok: true,
    id: mov.id,
    monto,
    metodo: metodo.banco,
    disponible: e?.disponible ?? null,
    permitido_dia: e?.permitido_dia ?? null,
    estado: e?.estado ?? null,
  });
});
