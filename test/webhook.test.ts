import assert from "node:assert/strict";
import test from "node:test";
import {
  asunto,
  autorizado,
  cuerpo,
  leerPayload,
  permitido,
  remitentes,
} from "../supabase/functions/_shared/webhook.ts";
import { aTexto } from "../supabase/functions/_shared/texto.ts";
import { parsear } from "../supabase/functions/_shared/parsers.ts";
import { BCP_TARJETA } from "./correos.ts";

const BANCOS = [
  "notificaciones@yape.pe",
  "notificaciones@notificacionesbcp.com.pe",
  "servicioalcliente@netinterbank.com.pe",
];

test("Postmark", () => {
  const p = {
    From: "BCP Notificaciones <notificaciones@notificacionesbcp.com.pe>",
    FromFull: { Email: "notificaciones@notificacionesbcp.com.pe" },
    Subject: "Realizaste un consumo",
    TextBody: "hola",
    HtmlBody: "<p>hola</p>",
  };
  assert.ok(remitentes(p).includes("notificaciones@notificacionesbcp.com.pe"));
  assert.deepEqual(cuerpo(p), { crudo: "hola", esHtml: false });
  assert.equal(asunto(p), "Realizaste un consumo");
});

test("CloudMailin", () => {
  const p = {
    envelope: { from: "notificaciones@yape.pe" },
    headers: { subject: "Tu yapeo" },
    plain: "hola",
    html: "<p>hola</p>",
  };
  assert.ok(remitentes(p).includes("notificaciones@yape.pe"));
  assert.deepEqual(cuerpo(p), { crudo: "hola", esHtml: false });
  assert.equal(asunto(p), "Tu yapeo");
});

test("Mailgun", () => {
  const p = { sender: "servicioalcliente@netinterbank.com.pe", "body-plain": "hola" };
  assert.ok(remitentes(p).includes("servicioalcliente@netinterbank.com.pe"));
  assert.deepEqual(cuerpo(p), { crudo: "hola", esHtml: false });
});

test("sin texto plano cae al HTML", () => {
  assert.deepEqual(cuerpo({ HtmlBody: "<p>hola</p>" }), { crudo: "<p>hola</p>", esHtml: true });
  // Un TextBody en blanco no cuenta como cuerpo: hay que caer al HTML
  assert.deepEqual(
    cuerpo({ TextBody: "   ", HtmlBody: "<p>hola</p>" }),
    { crudo: "<p>hola</p>", esHtml: true },
  );
  assert.equal(cuerpo({}), null);
});

test("el remitente se compara sin el nombre ni mayúsculas", () => {
  assert.deepEqual(remitentes({ From: "YAPE <Notificaciones@Yape.PE>" }), ["notificaciones@yape.pe"]);
  assert.deepEqual(remitentes({}), []);
});

test("reenvío de Gmail: el sobre es tuyo, la cabecera es del banco", () => {
  // Es exactamente lo que manda CloudMailin cuando reenvías desde Gmail
  const p = {
    envelope: { from: "sagarkishnani67@gmail.com" },
    headers: { from: "BCP Notificaciones <notificaciones@notificacionesbcp.com.pe>" },
    plain: "hola",
  };
  const de = remitentes(p);
  assert.ok(de.includes("sagarkishnani67@gmail.com"));
  assert.ok(de.includes("notificaciones@notificacionesbcp.com.pe"));
  // Pasa por la cabecera, sin necesidad de configurar REMITENTES
  assert.equal(permitido(de, undefined, BANCOS), true);
});

test("allowlist de remitentes", () => {
  assert.equal(permitido(["notificaciones@yape.pe"], undefined, BANCOS), true);
  assert.equal(permitido(["cualquiera@ejemplo.com"], undefined, BANCOS), false);
  assert.equal(permitido(["yo@gmail.com"], "yo@gmail.com", BANCOS), true);
  assert.equal(permitido([], "yo@gmail.com", BANCOS), false);
});

test("autorización por Bearer y por Basic", () => {
  assert.equal(autorizado("Bearer secreto", "secreto"), true);
  assert.equal(autorizado("Bearer otro", "secreto"), false);
  assert.equal(autorizado(`Basic ${btoa("pace:secreto")}`, "secreto"), true);
  assert.equal(autorizado(`Basic ${btoa("pace:malo")}`, "secreto"), false);
  // Sin token configurado no entra nadie
  assert.equal(autorizado("Bearer loquesea", undefined), false);
  assert.equal(autorizado(null, "secreto"), false);
});

test("payload JSON y payload de formulario", async () => {
  const j = new Request("https://x/", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ TextBody: "hola" }),
  });
  assert.equal((await leerPayload(j)).TextBody, "hola");

  const form = new FormData();
  form.set("body-plain", "hola");
  form.set("sender", "notificaciones@yape.pe");
  const f = new Request("https://x/", { method: "POST", body: form });
  assert.equal((await leerPayload(f))["body-plain"], "hola");
});

test("webhook completo: Postmark con el correo real del BCP", async () => {
  const p = {
    FromFull: { Email: "notificaciones@notificacionesbcp.com.pe" },
    TextBody: BCP_TARJETA,
  };
  assert.equal(permitido(remitentes(p), undefined, BANCOS), true);
  const c = cuerpo(p)!;
  const mov = (await parsear(aTexto(c.crudo, c.esHtml)))!;
  assert.equal(mov.monto, 78.29);
  assert.equal(mov.ref_operacion, "0000497442");
});
