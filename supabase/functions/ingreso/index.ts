// ============================================================
// POST /ingreso — endpoint del Atajo "Ingreso"
//
// { "monto": 5000, "fuente": "Oficina", "clase": "sueldo" }
//
// Header: Authorization: Bearer <SHORTCUT_TOKEN>
//
// Tres clases y solo una toca el ciclo:
//
//   sueldo  el ingreso principal. Cierra el ciclo anterior
//           (barriendo el sobrante al ahorro) y abre el
//           siguiente desde hoy. El ciclo va de cobro a cobro:
//           si el sueldo llega tarde, el anterior se estira.
//   extra   cualquier otro ingreso del ciclo en curso.
//   retiro  sacar de ahorros. Suma a la caja, no al ahorro.
//
// Toda la decisión está en registrar_ingreso() (006_panel.sql).
// Acá solo se traduce el body y se manda.
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { leerMonto, resolverClase } from "../_shared/vocabulario.ts";
import { json, tokenDe, tokenValido } from "../_shared/http.ts";

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

  const monto = leerMonto(body.monto);
  if (monto === null) return json({ error: "Falta un monto válido" }, 400);

  const { clase, cruda } = resolverClase(body.clase ?? body.tipo);

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await db.rpc("registrar_ingreso", {
    p_fuente: String(body.fuente ?? (clase === "sueldo" ? "Sueldo" : "Otro")),
    p_monto: monto,
    p_clase: clase,
    p_nota: body.nota ?? (cruda ? `clase cruda: ${cruda}` : null),
    // Rotar de ciclo barre el sobrante al ahorro y no se deshace
    // con un toque. Un `sueldo` con el ciclo recién empezado se
    // registra igual pero no rota, salvo que lo pidas explícito.
    p_forzar: body.forzar === true,
  });

  if (error) {
    console.error("registrar_ingreso falló:", error);
    return json({ error: "No se pudo registrar", detalle: error.message }, 500);
  }

  const e = data?.estado ?? null;

  return json({
    ...data,
    resumen: data?.rotado
      ? `Ciclo nuevo abierto. Bolsa S/ ${e?.bolsa ?? "?"} · hoy S/ ${e?.permitido_dia ?? "?"}`
      : `Ingreso registrado. Bolsa S/ ${e?.bolsa ?? "?"} · hoy S/ ${e?.permitido_dia ?? "?"}`,
  });
});
