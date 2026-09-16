// ============================================================
// Los cuatro parsers
//
// Cada uno decide si el correo es suyo mirando el cuerpo, no el
// remitente: los bancos cambian de dominio de envío más seguido
// que de plantilla.
//
// `banco` guarda el sistema de origen (BCP, Yape, Plin), no la
// cuenta de donde salió la plata. Es lo que hace que el índice
// único (banco, ref_operacion) sea un espacio de numeración
// limpio: un Nº de operación de Yape y uno de tarjeta BCP pueden
// coincidir sin ser el mismo gasto.
// ============================================================

import { campo, campoRe, fecha, hash, moneda, monto } from "./texto.ts";

export type Movimiento = {
  fecha: string;
  monto: number;
  moneda: string;
  comercio: string | null;
  banco: string;
  tipo: string;
  origen: "email";
  tarjeta_4d: string | null;
  ref_operacion: string | null;
  hash_origen: string | null;
  raw: Record<string, unknown>;
};

type Parser = {
  nombre: string;
  detecta: (t: string) => boolean;
  parsea: (t: string) => Movimiento | null;
};

// El "Nº" puede venir como º, ° o simplemente N. Y en P2P no se
// puede buscar solo "de operacion" porque antes aparece
// "Fecha y Hora de la operación".
const N_OPERACION = /N[ºo°.]?\s*de\s+operacion(?:\s+Yape)?\s*[:|*]*\s*([^\n|]+)/i;

// ------------------------------------------------------------
// BCP — consumo con tarjeta
// ------------------------------------------------------------
const bcpTarjeta: Parser = {
  nombre: "bcp_tarjeta",
  detecta: (t) => /consumo\s+tarjeta\s+de\s+(credito|debito)/i.test(t),
  parsea: (t) => {
    const tipoTxt = campo(t, "Operacion realizada") ?? "";
    const importe =
      monto(campo(t, "Total del consumo")) ??
      monto(campoRe(t, /consumo de\s*(S\/\s*[\d.,]+)/i));
    const cuando = fecha(campo(t, "Fecha y hora"));
    if (!importe || !cuando) return null;

    return {
      fecha: cuando,
      monto: importe,
      moneda: moneda(campo(t, "Total del consumo")),
      comercio: campo(t, "Empresa"),
      banco: "BCP",
      tipo: /debito/i.test(tipoTxt) ? "debito" : "credito",
      origen: "email",
      tarjeta_4d: campoRe(t, /\*{2,}\s*(\d{4})/),
      ref_operacion: campoRe(t, /Numero de operacion\s*[:|*]*\s*([^\n|]+)/i),
      hash_origen: null,
      // `empresa` no va en raw a propósito: acá significa comercio, y
      // el contrato reserva esa clave para el proveedor de un servicio.
      raw: { fuente: "bcp_tarjeta", operacion: tipoTxt },
    };
  },
};

// ------------------------------------------------------------
// Yape — pago de servicio
//
// El que más información trae: el código de usuario es la llave
// real contra la tabla `servicios`, mejor que el nombre de la
// empresa.
// ------------------------------------------------------------
const yapeServicio: Parser = {
  nombre: "yape_servicio",
  detecta: (t) => /codigo\s+de\s+usuario/i.test(t),
  parsea: (t) => {
    const importe = monto(campo(t, "Monto total"));
    const cuando = fecha(campo(t, "Fecha y hora"));
    if (!importe || !cuando) return null;

    const empresa = campo(t, "Empresa");

    return {
      fecha: cuando,
      monto: importe,
      moneda: moneda(campo(t, "Monto total")),
      comercio: empresa,
      banco: "Yape",
      tipo: "yape",
      origen: "email",
      tarjeta_4d: null,
      ref_operacion: campoRe(t, N_OPERACION),
      hash_origen: null,
      raw: {
        fuente: "yape_servicio",
        empresa,
        codigo_usuario: campo(t, "Codigo de usuario"),
        servicio: campo(t, "Servicio"),
        numero_recibo: campo(t, "Numero de recibo"),
        vencimiento: campo(t, "Vencimiento de documento"),
      },
    };
  },
};

// ------------------------------------------------------------
// Yape — transferencia a una persona
//
// El nombre llega truncado ("Antuanet Var*"), pero el correo
// también trae los últimos dígitos del celular. Los dos juntos
// hacen una llave estable para `destinatarios`; el nombre solo
// se presta a colisiones.
// ------------------------------------------------------------
const yapeP2P: Parser = {
  nombre: "yape_p2p",
  detecta: (t) => /nombre\s+del\s+beneficiario/i.test(t),
  parsea: (t) => {
    const importe = monto(campo(t, "Monto de yapeo"));
    const cuando = fecha(campo(t, "Fecha y Hora de la operacion"));
    if (!importe || !cuando) return null;

    const nombre = campo(t, "Nombre del Beneficiario");
    const celular = campo(t, "Celular del Beneficiario");
    const sufijo = celular ? celular.replace(/\D/g, "").slice(-3) : "";

    return {
      fecha: cuando,
      monto: importe,
      moneda: moneda(campo(t, "Monto de yapeo")),
      comercio: null,
      banco: "Yape",
      tipo: "yape",
      origen: "email",
      tarjeta_4d: null,
      ref_operacion: campoRe(t, N_OPERACION),
      hash_origen: null,
      raw: {
        fuente: "yape_p2p",
        destinatario: sufijo ? `${nombre} #${sufijo}` : nombre,
        destinatario_nombre: nombre,
        celular_beneficiario: celular,
      },
    };
  },
};

// ------------------------------------------------------------
// Plin — llega por Interbank
//
// Ojo: este correo sí viene de Interbank, pero solo cubre Plin.
// El consumo con tarjeta Interbank sigue sin canal de correo y
// sigue dependiendo del Atajo.
// ------------------------------------------------------------
const plin: Parser = {
  nombre: "plin",
  detecta: (t) => /constancia\s+de\s+pago\s+plin/i.test(t) || /codigo\s+de\s+operacion/i.test(t),
  parsea: (t) => {
    const crudo = campo(t, "Monto y moneda");
    const importe = monto(crudo);
    const cuando = fecha(campo(t, "Fecha y hora"));
    if (!importe || !cuando) return null;

    const nombre = campo(t, "Destinatario");

    return {
      fecha: cuando,
      monto: importe,
      moneda: moneda(crudo),
      comercio: null,
      banco: "Plin",
      tipo: "plin",
      origen: "email",
      tarjeta_4d: null,
      ref_operacion: campo(t, "Codigo de operacion"),
      hash_origen: null,
      raw: {
        fuente: "plin",
        destinatario: nombre,
        destinatario_nombre: nombre,
        cuenta_cargo: campo(t, "Cuenta cargo"),
        destino: campo(t, "Destino"),
      },
    };
  },
};

// El orden importa: yape_servicio antes que yape_p2p porque un
// correo de servicio no trae "Nombre del Beneficiario", pero si
// algún día lo trajera, el código de usuario manda.
const PARSERS: Parser[] = [yapeServicio, yapeP2P, bcpTarjeta, plin];

export async function parsear(texto: string): Promise<Movimiento | null> {
  for (const p of PARSERS) {
    if (!p.detecta(texto)) continue;

    const mov = p.parsea(texto);
    if (!mov) return null;

    // Sin número de operación no hay deduplicación por referencia,
    // así que el hash del contenido hace de red.
    if (!mov.ref_operacion) {
      mov.hash_origen = await hash(`${p.nombre}|${mov.monto}|${mov.fecha}|${texto}`);
    }
    return mov;
  }
  return null;
}
