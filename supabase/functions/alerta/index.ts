// ============================================================
// POST /alerta — lo que dispara el cron
//
// Header: Authorization: Bearer <PANEL_TOKEN>
//
//   ?modo=diario   el resumen de la mañana: siempre avisa
//   ?modo=cambio   solo si el estado subió (o sigue en rojo)
//
// La decisión de avisar y el texto salen de evaluar_alerta()
// (006_panel.sql). Acá solo queda el POST al webhook, que es lo
// único que Postgres no puede hacer sin pg_net.
//
// Con ?dry=1 devuelve lo que habría mandado sin mandarlo — para
// ver cómo queda el mensaje sin gastarse una notificación.
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { json, preflight, tokenDe, tokenValido } from "../_shared/http.ts";
import { enviarAviso } from "../_shared/notificar.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight();

  const esperado = Deno.env.get("PANEL_TOKEN") ?? Deno.env.get("SHORTCUT_TOKEN");
  if (!tokenValido(tokenDe(req, true), esperado)) {
    return json({ error: "No autorizado" }, 401, true);
  }

  const q = new URL(req.url).searchParams;
  const modo = q.get("modo") === "diario" ? "diario" : "cambio";
  const dry = q.get("dry") === "1";

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await db.rpc("evaluar_alerta", { p_modo: modo });

  if (error) {
    console.error("evaluar_alerta falló:", error);
    return json({ error: "No se pudo evaluar", detalle: error.message }, 500, true);
  }

  const a = Array.isArray(data) ? data[0] : data;

  // Sin ciclo abierto no hay nada que evaluar. Responde 200: el
  // cron reintentaría un error y esto no se arregla reintentando.
  if (!a) return json({ ok: true, notificado: false, motivo: "Sin ciclo abierto" }, 200, true);

  if (!a.notificar || dry) {
    return json({
      ok: true,
      notificado: false,
      motivo: dry ? "dry run" : `estado ${a.anterior} → ${a.estado}, sin novedad`,
      ...a,
    }, 200, true);
  }

  const envio = await enviarAviso(Deno.env.get("ALERTA_WEBHOOK_URL"), {
    titulo: a.titulo,
    cuerpo: a.cuerpo,
    estado: a.estado,
  });

  if (!envio.enviado) console.error("aviso no salió:", envio.detalle);

  return json({ ok: true, notificado: envio.enviado, ...envio, ...a }, 200, true);
});
