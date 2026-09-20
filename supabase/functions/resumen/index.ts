// ============================================================
// GET /resumen — lo que lee el panel
//
// Header: Authorization: Bearer <PANEL_TOKEN>
//   (o ?token=... , para poder abrir el panel desde un enlace)
//
// Devuelve el jsonb de panel() tal cual. No recalcula nada: los
// números son los de estado_ciclo() y punto. Si el panel
// empezara a sumar por su cuenta habría dos verdades y la del
// celular sería la que se mira.
//
// Existe este endpoint en vez de pegarle a PostgREST desde el
// navegador porque RLS está activo y sin políticas públicas: la
// anon key no lee nada. La alternativa sería meter la
// service_role key en el navegador, que es exactamente lo que no
// se hace nunca.
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { json, preflight, tokenDe, tokenValido } from "../_shared/http.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight();
  if (req.method !== "GET" && req.method !== "POST") {
    return json({ error: "Solo GET" }, 405, true);
  }

  // Un token propio del panel: vive en el navegador del celular,
  // que es un sitio más expuesto que el Atajo. Rotarlo no
  // obliga a reconfigurar el Atajo.
  const esperado = Deno.env.get("PANEL_TOKEN") ?? Deno.env.get("SHORTCUT_TOKEN");
  if (!tokenValido(tokenDe(req, true), esperado)) {
    return json({ error: "No autorizado" }, 401, true);
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const periodo = new URL(req.url).searchParams.get("periodo");

  const { data, error } = await db.rpc("panel", { p_periodo: periodo ?? null });

  if (error) {
    console.error("panel falló:", error);
    return json({ error: "No se pudo leer", detalle: error.message }, 500, true);
  }

  return json(data, 200, true);
});
