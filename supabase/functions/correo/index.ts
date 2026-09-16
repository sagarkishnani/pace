// ============================================================
// POST /correo — webhook del proveedor de correo entrante
//
// El proveedor recibe el correo del banco y hace POST acá con el
// cuerpo ya parseado. Esta función lo convierte en un movimiento;
// el enriquecimiento (servicio, comercio, categoría, ciclo) lo
// hacen los triggers de la migración 003.
//
// Header: Authorization: Bearer <CORREO_TOKEN>, o Basic con el
// token como contraseña — que es como lo manda Postmark cuando
// pones credenciales en la URL del webhook.
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { aTexto } from "../_shared/texto.ts";
import { parsear } from "../_shared/parsers.ts";
import {
  asunto,
  autorizado,
  cuerpo,
  leerPayload,
  permitido,
  remitentes,
} from "../_shared/webhook.ts";

// Cualquiera que sepa la dirección puede escribirle haciéndose
// pasar por el banco. El daño máximo es un movimiento inventado
// —que además sale en sin_resolver()— pero cerrar la puerta es
// gratis.
const REMITENTES = [
  "notificaciones@yape.pe",
  "notificaciones@notificacionesbcp.com.pe",
  "servicioalcliente@netinterbank.com.pe",
];

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Solo POST" }, 405);

  if (!autorizado(req.headers.get("Authorization"), Deno.env.get("CORREO_TOKEN"))) {
    return json({ error: "No autorizado" }, 401);
  }

  let payload;
  try {
    payload = await leerPayload(req);
  } catch {
    return json({ error: "Payload ilegible" }, 400);
  }

  const de = remitentes(payload);

  // Los "ignorado" responden 200 a propósito: el proveedor reintenta
  // ante un error, y ninguno de estos casos se arregla reintentando.
  if (!permitido(de, Deno.env.get("REMITENTES"), REMITENTES)) {
    console.log(`remitente rechazado: ${de.join(", ") || "(sin remitente)"}`);
    return json({ ok: true, ignorado: "remitente" });
  }

  const c = cuerpo(payload);
  if (!c) return json({ ok: true, ignorado: "sin cuerpo" });

  const mov = await parsear(aTexto(c.crudo, c.esHtml));
  if (!mov) {
    console.log(`sin parser para: ${asunto(payload)}`);
    return json({ ok: true, ignorado: "sin parser" });
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await db.from("movimientos").insert(mov).select("id").single();

  if (error) {
    // 23505 es el índice único (banco, ref_operacion): el correo ya
    // se procesó. Tiene que contar como éxito o el proveedor queda
    // reintentando en bucle.
    if (error.code === "23505") {
      console.log(`duplicado, ya estaba: op ${mov.ref_operacion}`);
      return json({ ok: true, duplicado: true });
    }
    console.error("insert falló:", error);
    return json({ error: "No se pudo registrar" }, 500);
  }

  console.log(`${mov.raw.fuente}: S/ ${mov.monto} op ${mov.ref_operacion ?? "-"}`);
  return json({ ok: true, id: data.id, monto: mov.monto, fuente: mov.raw.fuente });
});
