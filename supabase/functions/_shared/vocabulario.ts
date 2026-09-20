// ============================================================
// El vocabulario que entienden los endpoints manuales
//
// Vive acá y no dentro del handler por lo mismo que webhook.ts:
// dentro del handler no se puede probar, porque el handler
// importa Deno y supabase-js.
//
// El menú del Atajo está hardcodeado en iOS y no se sincroniza
// con nada. Por eso el endpoint acepta más claves de las que el
// menú muestra: cambiar el menú es un trámite manual en el
// iPhone, y mientras tanto lo viejo tiene que seguir entrando.
// ============================================================

export type Metodo = { banco: string; tipo: string };

// `banco` es el sistema de origen, no la cuenta. Mantiene limpio
// el espacio de numeración del índice (banco, ref_operacion).
//
// `tipo` es de dónde sale la plata, y ahí es donde importa la
// diferencia entre débito y crédito: el débito ya salió de la
// cuenta, el crédito llega después como estado de cuenta. El
// motor cuenta los dos como gasto del ciclo (ver 006_panel.sql),
// pero solo separándolos se sabe cuánto de la cuenta todavía
// está comprometido.
export const METODOS: Record<string, Metodo> = {
  // Los cinco del menú del Atajo, en el orden en que están allá
  bcp_credito: { banco: "BCP", tipo: "credito" },
  bcp_debito: { banco: "BCP", tipo: "debito" },
  interbank_credito: { banco: "Interbank", tipo: "credito" },
  interbank_debito: { banco: "Interbank", tipo: "debito" },
  efectivo: { banco: "Efectivo", tipo: "efectivo" },

  // Fuera del menú: Yape sale de la cuenta BCP y Plin de la
  // Interbank, así que registrarlos como el débito que son está
  // bien. Se aceptan igual porque los parsers de correo emiten
  // estos tipos y porque el trigger aprende destinatarios solo
  // para yape y plin.
  yape: { banco: "Yape", tipo: "yape" },
  plin: { banco: "Plin", tipo: "plin" },

  // Pagar el estado de cuenta no es gasto nuevo: el consumo ya
  // contó el día que pasaste la tarjeta. estado_ciclo() deja
  // pago_tarjeta fuera de la bolsa; se registra para que la
  // reconciliación cuadre contra el extracto del banco.
  pago_bcp: { banco: "BCP", tipo: "pago_tarjeta" },
  pago_interbank: { banco: "Interbank", tipo: "pago_tarjeta" },

  // Monedero: la recarga es el gasto, el consumo ya está pagado
  recarga_monedero: { banco: "Efectivo", tipo: "recarga_monedero" },
  consumo_monedero: { banco: "Efectivo", tipo: "consumo_monedero" },
};

// Lo que mandaba el Atajo antes de separar débito de crédito.
// Un gasto no se pierde por un cambio de nombre.
const ALIAS: Record<string, string> = {
  bcp: "bcp_credito",
  interbank: "interbank_credito",
  bcp_credito_visa: "bcp_credito",
  efectivo_soles: "efectivo",
};

export const METODO_DEFECTO = "interbank_credito";

// Vocabulario canónico de categorías. Los parsers de correo tienen
// que emitir estas mismas al resolver comercios.categoria, si no el
// resumen sale partido en dos vocabularios.
// Solo gasto variable: los fijos y los servicios no pasan por acá.
export const CATEGORIAS = new Set([
  "comida", // mercado, bodega, supermercado
  "restaurante", // salir a comer, delivery
  "transporte", // taxi, combustible, pasajes
  "salud", // farmacia, consultas
  "hogar", // cosas para la casa
  "personal", // ropa, cortes, gym
  "otro",
]);

const limpiar = (v: unknown): string | null => {
  if (v == null) return null;
  const s = String(v).trim().toLowerCase().replace(/[\s-]+/g, "_");
  return s === "" ? null : s;
};

// Un método desconocido no bota el registro: cae al de siempre y
// la clave cruda queda en raw. Estás parado en una caja cuando
// esto corre; perder el gasto es peor que perder el metadato.
export function resolverMetodo(valor: unknown): {
  clave: string;
  metodo: Metodo;
  cruda: string | null;
} {
  const pedida = limpiar(valor);
  const clave = pedida && (ALIAS[pedida] ?? pedida);

  if (clave && METODOS[clave]) {
    return { clave, metodo: METODOS[clave], cruda: null };
  }
  return {
    clave: METODO_DEFECTO,
    metodo: METODOS[METODO_DEFECTO],
    cruda: pedida,
  };
}

// Mismo criterio con la categoría, salvo que acá no hay valor por
// defecto razonable: entra nula y se resuelve en la reconciliación
// semanal, con el comercio a la vista.
export function resolverCategoria(valor: unknown): {
  categoria: string | null;
  cruda: string | null;
} {
  const pedida = limpiar(valor);
  if (pedida && CATEGORIAS.has(pedida)) {
    return { categoria: pedida, cruda: null };
  }
  return { categoria: null, cruda: pedida };
}

// ------------------------------------------------------------
// Ingresos
//
// Solo `sueldo` toca el ciclo: lo cierra y abre el siguiente.
// `retiro` suma a la caja pero no al ahorro — si contara, el
// motor ahorraría el 30% de plata que acabas de sacar del ahorro.
// ------------------------------------------------------------
export const CLASES_INGRESO = new Set(["sueldo", "extra", "retiro"]);

export function resolverClase(valor: unknown): {
  clase: string;
  cruda: string | null;
} {
  const pedida = limpiar(valor);
  if (pedida && CLASES_INGRESO.has(pedida)) return { clase: pedida, cruda: null };
  return { clase: "extra", cruda: pedida };
}

// Un monto que no se puede leer sí bota el registro: es lo único
// que no se puede reconstruir después.
export function leerMonto(valor: unknown): number | null {
  if (typeof valor === "string") {
    // El Atajo puede mandar "S/ 42,80" según la config regional
    const limpio = valor.replace(/[^\d.,-]/g, "").replace(",", ".");
    const n = Number(limpio);
    return Number.isFinite(n) && n > 0 ? n : null;
  }
  const n = Number(valor);
  return Number.isFinite(n) && n > 0 ? n : null;
}
