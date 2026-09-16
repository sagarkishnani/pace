import assert from "node:assert/strict";
import test from "node:test";
import { aTexto } from "../supabase/functions/_shared/texto.ts";
import { parsear } from "../supabase/functions/_shared/parsers.ts";
import { BCP_TARJETA, PLIN, YAPE_P2P, YAPE_SERVICIO } from "./correos.ts";

const leer = (crudo: string) => parsear(aTexto(crudo, false));

test("BCP tarjeta", async () => {
  const m = (await leer(BCP_TARJETA))!;
  assert.equal(m.monto, 78.29);
  assert.equal(m.moneda, "PEN");
  assert.equal(m.comercio, "TOTTUS JOCKEY PLAZA");
  assert.equal(m.banco, "BCP");
  assert.equal(m.tipo, "credito");
  assert.equal(m.tarjeta_4d, "3320");
  assert.equal(m.ref_operacion, "0000497442");
  // 05:15 PM en Lima (UTC-5) son las 22:15 UTC
  assert.equal(m.fecha, "2026-09-05T22:15:00.000Z");
});

test("Yape servicio: el código de usuario es la llave", async () => {
  const m = (await leer(YAPE_SERVICIO))!;
  assert.equal(m.monto, 119);
  assert.equal(m.banco, "Yape");
  assert.equal(m.tipo, "yape");
  assert.equal(m.ref_operacion, "01127334");
  assert.equal(m.raw.codigo_usuario, "73508992");
  assert.equal(m.raw.empresa, "WIN Internet");
  assert.equal(m.raw.vencimiento, "28/08/2026");
  assert.equal(m.fecha, "2026-08-29T19:56:00.000Z");
});

test("Yape P2P: nombre truncado + últimos dígitos del celular", async () => {
  const m = (await leer(YAPE_P2P))!;
  assert.equal(m.monto, 10);
  assert.equal(m.tipo, "yape");
  assert.equal(m.ref_operacion, "34812686");
  assert.equal(m.raw.destinatario, "Antuanet Var* #204");
  assert.equal(m.raw.destinatario_nombre, "Antuanet Var*");
  assert.equal(m.fecha, "2026-09-16T04:26:00.000Z");
});

test("Plin", async () => {
  const m = (await leer(PLIN))!;
  assert.equal(m.monto, 54);
  assert.equal(m.banco, "Plin");
  assert.equal(m.tipo, "plin");
  assert.equal(m.ref_operacion, "55063910");
  assert.equal(m.raw.destinatario, "El M Anonima C");
  assert.equal(m.fecha, "2026-09-02T16:57:00.000Z");
});

test("cada correo lo agarra un solo parser", async () => {
  const fuentes = await Promise.all(
    [BCP_TARJETA, PLIN, YAPE_P2P, YAPE_SERVICIO].map(async (c) => (await leer(c))!.raw.fuente),
  );
  assert.deepEqual(fuentes.sort(), ["bcp_tarjeta", "plin", "yape_p2p", "yape_servicio"]);
});

test("un correo cualquiera no genera movimiento", async () => {
  assert.equal(await leer("Hola, tu estado de cuenta ya está disponible."), null);
});

test("sin número de operación cae al hash", async () => {
  const m = (await leer(BCP_TARJETA.replace(/Número de operación.*/g, "")))!;
  assert.equal(m.ref_operacion, null);
  assert.match(m.hash_origen!, /^[0-9a-f]{64}$/);
});
