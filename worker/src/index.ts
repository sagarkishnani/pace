// ============================================================
// Cloudflare Email Worker
//
// Recibe los correos del banco, los parsea e inserta en
// `movimientos`. Nada más: el enriquecimiento (servicio,
// comercio, categoría, ciclo) lo hace la base con los triggers
// de la migración 003.
// ============================================================

import PostalMime from "postal-mime";
import { aTexto } from "./texto.ts";
import { parsear } from "./parsers.ts";

type Env = {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  REMITENTES?: string;
};

type Correo = {
  from: string;
  raw: ReadableStream;
  headers: Headers;
  setReject: (razon: string) => void;
};

// Cualquiera que sepa la dirección puede mandarle un correo al
// Worker haciéndose pasar por el banco. El daño máximo es un
// movimiento inventado —que además sale en sin_resolver()— pero
// no cuesta nada cerrar la puerta.
const REMITENTES = [
  "notificaciones@yape.pe",
  "notificaciones@notificacionesbcp.com.pe",
  "servicioalcliente@netinterbank.com.pe",
];

const permitido = (env: Env, ...direcciones: (string | undefined)[]) => {
  const lista = (env.REMITENTES?.split(",").map((s) => s.trim().toLowerCase()) ?? [])
    .concat(REMITENTES);
  return direcciones.some((d) => d && lista.includes(d.toLowerCase()));
};

export default {
  async email(mensaje: Correo, env: Env): Promise<void> {
    const correo = await PostalMime.parse(await new Response(mensaje.raw).arrayBuffer());
    const remitente = correo.from?.address;

    // Si reenvías desde Gmail, el sobre lleva tu dirección y no la
    // del banco: agrega la tuya a REMITENTES.
    if (!permitido(env, mensaje.from, remitente)) {
      console.log(`remitente rechazado: ${mensaje.from} / ${remitente}`);
      mensaje.setReject("Remitente no reconocido");
      return;
    }

    const texto = correo.text
      ? aTexto(correo.text, false)
      : aTexto(correo.html ?? "", true);

    const mov = await parsear(texto);
    if (!mov) {
      console.log(`sin parser para: ${correo.subject ?? "(sin asunto)"}`);
      return;
    }

    const r = await fetch(`${env.SUPABASE_URL}/rest/v1/movimientos`, {
      method: "POST",
      headers: {
        apikey: env.SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
        "Content-Type": "application/json",
        Prefer: "return=minimal",
      },
      body: JSON.stringify(mov),
    });

    if (r.ok) {
      console.log(`${mov.raw.fuente}: S/ ${mov.monto} op ${mov.ref_operacion ?? "-"}`);
      return;
    }

    const detalle = await r.text();

    // 23505 es el índice único (banco, ref_operacion): el correo ya
    // se procesó. Cloudflare reintenta ante un error, así que esto
    // tiene que contar como éxito o el reintento queda en bucle.
    if (r.status === 409 || detalle.includes("23505")) {
      console.log(`duplicado, ya estaba: op ${mov.ref_operacion}`);
      return;
    }

    // Cualquier otro error sí debe reintentarse
    throw new Error(`insert falló (${r.status}): ${detalle}`);
  },
};
