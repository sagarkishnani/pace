// ============================================================
// POST /accion — las escrituras del panel
//
// Header: Authorization: Bearer <PANEL_TOKEN>
// Body:   { "accion": "...", ...campos }
//
// Un solo endpoint y no seis. Cada acción es una función de
// Postgres; acá solo se traduce el body y se llama. La lógica no
// vive en el navegador por la misma razón que los números: una
// sola fuente. Si "pagar un servicio" se implementara en el
// panel, habría dos versiones de la regla.
//
// El mapa de acciones es una allowlist explícita: sin ella, un
// body con `accion: "cerrar_ciclo"` llamaría cualquier función de
// la base con la service_role key.
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { json, preflight, tokenDe, tokenValido } from "../_shared/http.ts";
import { leerMonto, resolverMetodo } from "../_shared/vocabulario.ts";

type Cuerpo = Record<string, unknown>;

const texto = (v: unknown): string | null => {
  const s = v == null ? "" : String(v).trim();
  return s === "" ? null : s;
};
const entero = (v: unknown): number | null => {
  const n = Number(v);
  return Number.isInteger(n) ? n : null;
};
const numero = (v: unknown): number | null => {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};
const booleano = (v: unknown): boolean | null =>
  v === true || v === false ? v : null;

// accion → [función de Postgres, cómo se arman sus argumentos]
const ACCIONES: Record<string, { fn: string; args: (b: Cuerpo) => Record<string, unknown> }> = {
  // Registrar un ingreso. Con ciclos de calendario el panel nunca
  // rota desde acá: para eso está la acción `rotar`.
  ingreso: {
    fn: "registrar_ingreso",
    args: (b) => ({
      p_fuente: texto(b.fuente) ?? "Otro",
      p_monto: leerMonto(b.monto),
      p_clase: texto(b.clase) ?? "extra",
      p_nota: texto(b.nota),
      p_rotar: false,
    }),
  },

  // Pagar un fijo o un servicio: el movimiento entra enlazado y
  // por lo tanto fuera de la bolsa.
  pago: {
    fn: "registrar_pago",
    args: (b) => {
      const { metodo } = resolverMetodo(b.metodo);
      return {
        p_clase: texto(b.clase),
        p_id: texto(b.id),
        p_monto: leerMonto(b.monto),
        p_banco: metodo.banco,
        p_tipo: metodo.tipo,
        p_nota: texto(b.nota),
      };
    },
  },

  // El ritual del día 1, en una transacción
  rotar: {
    fn: "rotar_ciclo",
    args: (b) => ({
      p_inicio: texto(b.inicio),
      p_etiqueta: texto(b.etiqueta),
      p_ingresos: Array.isArray(b.ingresos) ? b.ingresos : null,
      p_config: b.config ?? null,
    }),
  },

  config: {
    fn: "actualizar_config",
    args: (b) => ({
      p_pct_ahorro: numero(b.pct_ahorro),
      p_monto_esposa: numero(b.monto_esposa),
      p_dia_inicio_eval: entero(b.dia_inicio_eval),
      p_alertas_activas: booleano(b.alertas_activas),
      p_nota: texto(b.nota),
    }),
  },

  fijo: {
    fn: "guardar_fijo",
    args: (b) => ({
      p_id: texto(b.id),
      p_nombre: texto(b.nombre),
      p_monto: numero(b.monto),
      p_dia_aprox: entero(b.dia_aprox),
      p_activo: booleano(b.activo),
    }),
  },

  servicio: {
    fn: "guardar_servicio",
    args: (b) => ({
      p_id: texto(b.id),
      p_nombre: texto(b.nombre),
      p_estimado: numero(b.estimado),
      p_dia_aprox: entero(b.dia_aprox),
      p_vence_el: texto(b.vence_el),
      p_empresa: texto(b.empresa),
      p_activo: booleano(b.activo),
    }),
  },

  // Solo lectura, pero vive acá porque lo pide el formulario de
  // reglas para el control deslizante del %
  simular: { fn: "simular_actual", args: () => ({}) },
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight();
  if (req.method !== "POST") return json({ error: "Solo POST" }, 405, true);

  const esperado = Deno.env.get("PANEL_TOKEN") ?? Deno.env.get("SHORTCUT_TOKEN");
  if (!tokenValido(tokenDe(req), esperado)) {
    return json({ error: "No autorizado" }, 401, true);
  }

  let body: Cuerpo;
  try {
    body = await req.json();
  } catch {
    return json({ error: "JSON inválido" }, 400, true);
  }

  const nombre = String(body.accion ?? "");
  const accion = ACCIONES[nombre];
  if (!accion) {
    return json({ error: `Acción desconocida: ${nombre}` }, 400, true);
  }

  // Rotar cierra el ciclo y barre el sobrante al ahorro. No se
  // deshace, así que no se dispara sin que el panel lo confirme
  // explícitamente: un toque perdido no puede costar un ciclo.
  if (nombre === "rotar" && body.confirmar !== true) {
    return json({ error: "Rotar el ciclo necesita confirmar: true" }, 400, true);
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await db.rpc(accion.fn, accion.args(body));

  if (error) {
    console.error(`${nombre} falló:`, error);
    return json({ ok: false, error: error.message }, 500, true);
  }

  return json(data, 200, true);
});
